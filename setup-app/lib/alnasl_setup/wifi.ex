defmodule AlnaslSetup.Wifi do
  @moduledoc """
  The box's Wi-Fi as the setup server and the hotspot daemon use it (was the wifi part of server.py):
  the wpa_supplicant configuration file, scans, connecting to a network and putting the old
  configuration back when that fails.

  Passphrases arrive in POST bodies, go into the root-only configuration file (0600) as a PSK and are
  never logged. A validation error raises `ArgumentError` with the text the page shows (Python's
  ValueError); the hotspot daemon catches it the same way.

  Called by the hotspot daemon in its own program: `scan/0`, `connect/4`, `parse_wpa/0`,
  `write_wpa/2`, `wlan_ip/0`, `wpa_conf/0`, `hotspot_active?/0`.
  """
  alias AlnaslSetup.{Diag, Json, Sys}
  alias AlnaslSetup.Server.{Py, State}

  @wpa_conf "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
  @hotspot_run "/run/alnasl-hotspot"
  @hotspot_active @hotspot_run <> "/active"
  @hotspot_join @hotspot_run <> "/join.json"
  @hotspot_scan @hotspot_run <> "/scan.json"

  def wpa_conf, do: @wpa_conf
  def hotspot_active?, do: Sys.exists?(@hotspot_active)

  # the waits, scaled in the tests
  defp s(seconds), do: seconds * Py.env(:wait_scale, 1)
  defp now, do: Py.monotonic()

  def hexify(s), do: Base.encode16(s, case: :lower)

  defp unhex!(h) do
    case Base.decode16(h, case: :mixed) do
      {:ok, b} -> b
      :error -> raise ArgumentError, "non-hexadecimal number found in fromhex() arg"
    end
  end

  defp ssid_text(hex), do: Json.scrub(unhex!(hex))

  # ------------------------------------------------------------------------ the configuration --

  @doc """
  `{country, networks}`; a network is `%{"ssid" => lowercase hex, "psk" => hex | nil, "hidden" => bool,
  "prio" => int}`. A clear passphrase in the file is turned into the PSK.
  """
  def parse_wpa do
    text = Sys.read(@wpa_conf)

    country =
      case Regex.run(~r/^country=(\w\w)/mu, text) do
        [_, c] -> c
        _ -> "BE"
      end

    nets =
      for [_, blk] <- Regex.scan(~r/network=\{(.*?)\}/s, text),
          d = block_kv(blk),
          Map.has_key?(d, "ssid") do
        ssid = d["ssid"]
        ssid = if String.starts_with?(ssid, "\""), do: hexify(String.trim(ssid, "\"")), else: ssid
        psk = d["psk"]

        psk =
          if psk && String.starts_with?(psk, "\"") do
            hexify(:crypto.pbkdf2_hmac(:sha, String.trim(psk, "\""), unhex!(ssid), 4096, 32))
          else
            psk
          end

        prio = Map.get(d, "priority", "0")
        prio = if prio == "", do: 0, else: Py.int!(prio)
        %{"ssid" => String.downcase(ssid), "psk" => psk, "hidden" => d["scan_ssid"] == "1", "prio" => prio}
      end

    {country, nets}
  end

  defp block_kv(blk) do
    blk
    |> Diag.splitlines()
    |> Enum.filter(&String.contains?(&1, "="))
    |> Enum.reduce(%{}, fn line, acc ->
      [k, v] = line |> String.trim() |> String.split("=", parts: 2)
      Map.put(acc, k, v)
    end)
  end

  @doc "Writes the configuration (0600). Networks as `parse_wpa/0` gives them."
  def write_wpa(country, nets) do
    out =
      ["ctrl_interface=/run/wpa_supplicant", "ctrl_interface_group=0", "update_config=0", "country=" <> country] ++
        Enum.flat_map(nets, fn n ->
          psk = n["psk"]

          ["network={", "\tssid=" <> n["ssid"], if(Py.truthy?(psk), do: "\tpsk=" <> psk, else: "\tkey_mgmt=NONE")] ++
            if(Py.truthy?(n["hidden"]), do: ["\tscan_ssid=1"], else: []) ++
            ["\tpriority=#{n["prio"]}", "}"]
        end)

    AlnaslSetup.Server.Box.write_private(@wpa_conf, Enum.join(out, "\n") <> "\n", follow: true)
  end

  defp wpa(args), do: Sys.run(["wpa_cli", "-p", "/run/wpa_supplicant", "-i", "wlan0" | args], timeout: 10)

  @doc "wpa_cli's \\xNN escapes back to UTF-8."
  def wpa_unescape(s) do
    s
    |> Json.scrub()
    |> then(&Regex.replace(~r/\\x([0-9a-fA-F]{2})/, &1, fn _, h -> <<String.to_integer(h, 16)::utf8>> end))
    |> String.to_charlist()
    |> Enum.map(fn c -> if c <= 255, do: c, else: ?? end)
    |> :erlang.list_to_binary()
    |> Json.scrub()
  end

  # Like wpa(), but stdout and stderr together (wpa_cli says 'Failed to connect' on stderr).
  defp wpa_o(args), do: Diag.wpa_cli(args)

  # True when a wpa_supplicant really answers on wlan0.
  #
  # Photon's wpa_supplicant@.service is Type=oneshot + RemainAfterExit: systemd reports it 'active' even
  # after the daemon it started with -B has died, so 'systemctl is-active' proves nothing.
  defp wpa_alive?, do: wpa_o(["ping"]) |> elem(1) |> String.trim() |> String.starts_with?("PONG")

  defp sysctl(args), do: Sys.run(["systemctl" | args], timeout: 60)

  @doc """
  Make sure wlan0 exists, is up, and a supplicant answers.

  Returns `%{"ok" => bool, "reason" => nil | code, "steps" => [text], "journal" => text}`.
  Reason codes: no_interface, supplicant_failed.
  """
  def ensure_wifi do
    steps =
      if Sys.exists?("/sys/class/net/wlan0") do
        []
      else
        out = Diag.runo(["modprobe", "brcmfmac"], 20) |> elem(1) |> String.trim()
        wait(10, 1, fn -> Sys.exists?("/sys/class/net/wlan0") end)
        ["wlan0 is missing; trying modprobe brcmfmac", if(out == "", do: "modprobe brcmfmac: done", else: out)]
      end

    if not Sys.exists?("/sys/class/net/wlan0") do
      %{
        "ok" => false,
        "reason" => "no_interface",
        "steps" => steps,
        "journal" => Enum.join(Diag.grep_lines(Diag.kernel_log(), "brcm|cfg80211|sdio|mmc1|firmware", 25), "\n")
      }
    else
      if Sys.exists?("/dev/rfkill"), do: Sys.run(["rfkill", "unblock", "wifi"])
      if not Sys.exists?(@wpa_conf), do: write_wpa("BE", [])
      {_rc, out} = Diag.runo(["ip", "link", "set", "dev", "wlan0", "up"], 10)
      steps = steps ++ ["ip link set wlan0 up: " <> or_ok(String.trim(out))]

      steps =
        if wpa_alive?() do
          steps
        else
          steps = steps ++ ["no supplicant answers on wlan0; restarting wpa_supplicant@wlan0"]
          sysctl(["stop", "wpa_supplicant@wlan0.service"])
          Sys.run(["pkill", "-x", "wpa_supplicant"])
          Py.nap(0.5)
          # a stale socket makes the new daemon refuse to start
          File.rm(Sys.path("/run/wpa_supplicant/wlan0"))
          Diag.runo(["ip", "link", "set", "dev", "wlan0", "up"], 10)
          {_rc, out} = sysctl(["restart", "wpa_supplicant@wlan0.service"])
          steps = if String.trim(out) != "", do: steps ++ [String.trim(out)], else: steps
          wait(12, 0.7, &wpa_alive?/0)

          if wpa_alive?() do
            steps
          else
            # Last attempt: the daemon directly, so its own error message is captured.
            {rc, out} = Diag.runo(["wpa_supplicant", "-B", "-s", "-i", "wlan0", "-c", @wpa_conf], 20)
            wait(8, 0.7, &wpa_alive?/0)
            steps ++ ["direct start: exit #{rc} #{String.trim(out)}"]
          end
        end

      if wpa_alive?() do
        %{"ok" => true, "reason" => nil, "steps" => steps, "journal" => ""}
      else
        {_rc, j} =
          Diag.runo(
            [
              "journalctl",
              "--no-pager",
              "-n",
              "30",
              "-o",
              "short-iso",
              "-u",
              "wpa_supplicant@wlan0.service",
              "-t",
              "wpa_supplicant"
            ],
            15
          )

        %{"ok" => false, "reason" => "supplicant_failed", "steps" => steps, "journal" => j}
      end
    end
  end

  defp or_ok(""), do: "ok"
  defp or_ok(s), do: s

  # up to n tries of the check, a nap after each failed one (Python's for/sleep/break loops)
  defp wait(0, _secs, _check), do: :ok

  defp wait(n, secs, check) do
    if check.() do
      :ok
    else
      Py.nap(secs)
      wait(n - 1, secs, check)
    end
  end

  # keeps the first-seen order of the SSIDs, the strongest signal of each (Python's dict)
  defp best(list) do
    {order, by} =
      Enum.reduce(list, {[], %{}}, fn n, {order, by} ->
        k = n["ssid"]

        case Map.fetch(by, k) do
          {:ok, %{"signal" => old}} when old >= :erlang.map_get("signal", n) -> {order, by}
          {:ok, _} -> {order, Map.put(by, k, n)}
          :error -> {[k | order], Map.put(by, k, n)}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&by[&1])
  end

  def parse_scan_results(out) do
    out
    |> Diag.splitlines()
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      p = String.split(line, "\t")

      with true <- length(p) >= 5 and Enum.at(p, 4) != "",
           {:ok, sig} <- Py.int(Enum.at(p, 2)),
           {:ok, freq} <- Py.int(Enum.at(p, 1)) do
        flags = Enum.at(p, 3)

        [
          %{
            "ssid" => wpa_unescape(Enum.at(p, 4)),
            "signal" => sig,
            "secured" => Enum.any?(~w(WPA WEP RSN SAE), &String.contains?(flags, &1)),
            "band" => if(freq > 4000, do: "5", else: "2.4")
          }
        ]
      else
        _ -> []
      end
    end)
    |> best()
  end

  def parse_iw_scan(out) do
    out
    |> String.split(~r/^BSS /m)
    |> Enum.drop(1)
    |> Enum.flat_map(fn blk ->
      case Regex.run(~r/^\s*SSID: (.*)$/mu, blk) do
        [_, raw] ->
          if String.trim(raw) == "" or String.contains?(raw, "\\x00") do
            []
          else
            sig =
              case Regex.run(~r/signal: (-?\d+)/, blk) do
                [_, v] -> String.to_integer(v)
                _ -> -90
              end

            freq =
              case Regex.run(~r/freq: (\d+)/, blk) do
                [_, v] -> String.to_integer(v)
                _ -> nil
              end

            secured = Regex.match?(~r/^\s*(RSN|WPA):/m, blk) or String.contains?(blk, "Privacy")

            [
              %{
                "ssid" => wpa_unescape(String.trim(raw)),
                "signal" => sig,
                "secured" => secured,
                "band" => if(freq && freq > 4000, do: "5", else: "2.4")
              }
            ]
          end

        _ ->
          []
      end
    end)
    |> best()
  end

  defp saved_names, do: parse_wpa() |> elem(1) |> MapSet.new(&ssid_text(&1["ssid"]))

  defp by_signal(nets), do: Enum.sort_by(nets, &(-&1["signal"]))

  @doc "The raw text of the last scan test (for the diagnostics)."
  def last_scan, do: State.get(:last_scan, "")

  @doc """
  Scan for networks. Never returns a bare empty list: when nothing was found the answer carries a
  reason code and the raw outputs, which the UI shows.
  """
  def scan do
    # hostapd has the radio: restarting the supplicant now would take it away
    if hotspot_active?(), do: hotspot_scan(), else: client_scan()
  end

  defp client_scan do
    t0 = now()
    info = ensure_wifi()
    raw = info["steps"]

    if info["reason"] do
      text = Enum.join(raw ++ [info["journal"]], "\n")
      State.put(:last_scan, Diag.redact("Wi-Fi scan test at #{Py.strftime("%H:%M:%S")}: #{info["reason"]}\n#{text}"))

      %{
        "available" => info["reason"] != "no_interface",
        "networks" => [],
        "reason" => info["reason"],
        "detail" => Diag.redact(text),
        "elapsed" => Py.round(now() - t0, 1)
      }
    else
      {nets, raw, refused, polls} = scan_loop(t0, raw)
      raw = raw ++ ["wpa_cli scan_results -> #{length(nets)} networks after #{f1(now() - t0)} s (#{polls} polls)"]

      {nets, source, raw} =
        if nets == [] and Diag.have?("iw") do
          {rc, out} = Diag.runo(["iw", "dev", "wlan0", "scan"], 25)
          raw = raw ++ ["iw dev wlan0 scan -> exit #{rc}, #{Py.len(out)} bytes"]

          case parse_iw_scan(out) do
            [] -> {nets, "wpa", raw ++ [out |> String.trim() |> Diag.splitlines() |> Enum.take(12) |> Enum.join("\n")]}
            iwn -> {iwn, "iw", raw}
          end
        else
          {nets, "wpa", raw}
        end

      raw = raw ++ [wpa_o(["status"]) |> elem(1) |> String.trim()]
      raw = if Diag.have?("iw"), do: raw ++ [Diag.runo(["iw", "reg", "get"], 8) |> elem(1) |> String.trim()], else: raw
      saved = saved_names()
      nets = nets |> by_signal() |> Enum.map(&Map.put(&1, "saved", MapSet.member?(saved, &1["ssid"])))

      State.put(
        :last_scan,
        Diag.redact(
          "Wi-Fi scan test at #{Py.strftime("%H:%M:%S")}: #{length(nets)} networks via #{source} in #{f1(now() - t0)} s\n" <>
            Enum.join(raw, "\n")
        )
      )

      res = %{"available" => true, "networks" => nets, "source" => source, "elapsed" => Py.round(now() - t0, 1)}

      if nets == [] do
        Map.merge(res, %{
          "reason" => if(refused >= 4, do: "scan_rejected", else: "no_results"),
          "detail" => Diag.redact(Enum.join(raw, "\n"))
        })
      else
        res
      end
    end
  end

  defp f1(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  # Python's while loop: ask for a scan, poll its results until they stop growing.
  defp scan_loop(t0, raw),
    do: scan_loop(%{deadline: t0 + s(20), started: 0.0, refused: 0, polls: 0, last_n: -1, nets: [], raw: raw})

  defp scan_loop(st) do
    if now() >= st.deadline do
      {st.nets, st.raw, st.refused, st.polls}
    else
      st =
        if st.started == 0.0 do
          {_rc, out} = wpa_o(["scan"])
          o = String.trim(out)
          st = %{st | raw: st.raw ++ ["wpa_cli scan -> " <> o]}

          cond do
            String.contains?(out, "FAIL-BUSY") ->
              # another scan is running (ours, or the supplicant's own): wait for its results
              Py.nap(1.5)
              %{st | started: now() - s(2)}

            String.ends_with?(o, "OK") ->
              %{st | started: now()}

            true ->
              {:refused, %{st | refused: st.refused + 1}}
          end
        else
          st
        end

      case st do
        {:refused, st} ->
          if st.refused >= 4 do
            {st.nets, st.raw, st.refused, st.polls}
          else
            Py.nap(1.5)
            scan_loop(st)
          end

        st ->
          Py.nap(1.5)
          st = %{st | polls: st.polls + 1}
          {_rc, out} = wpa_o(["scan_results"])
          cur = parse_scan_results(out)
          el = now() - st.started

          cond do
            cur != [] and ((length(cur) == st.last_n and el >= s(3.5)) or el >= s(12)) ->
              # results of a finished scan; accept once they stopped growing (or after a good wait)
              {cur, st.raw, st.refused, st.polls}

            cur != [] ->
              scan_loop(%{st | nets: cur, last_n: length(cur)})

            el > s(9) and st.polls < 12 ->
              # the scan never delivered: ask again once
              scan_loop(%{st | started: 0.0, last_n: 0})

            true ->
              scan_loop(%{st | last_n: 0})
          end
      end
    end
  end

  @doc "What the diagnostics may say about the Wi-Fi configuration: SSIDs, country, secured or not. Never keys."
  def summary do
    {country, nets} = parse_wpa()

    %{
      "country" => country,
      "lines" =>
        Enum.map(nets, fn n ->
          "#{ssid_text(n["ssid"])}  [#{if n["psk"], do: "secured", else: "open"}#{if n["hidden"], do: ", hidden", else: ""}]"
        end)
    }
  end

  def saved do
    {country, nets} = parse_wpa()

    %{
      "country" => country,
      "saved" =>
        Enum.map(
          nets,
          &%{"ssid" => ssid_text(&1["ssid"]), "secured" => Py.truthy?(&1["psk"]), "hidden" => &1["hidden"]}
        )
    }
  end

  @doc "wlan0's IPv4 address, or nil."
  def wlan_ip do
    {_rc, out} = Sys.run(["ip", "-j", "-4", "addr", "show", "wlan0"])

    case Json.decode_or_nil(out) do
      [%{"addr_info" => [%{"local" => ip} | _]} | _] -> ip
      _ -> nil
    end
  end

  @doc "Checks a network as given; returns the country in capitals. Raises ArgumentError."
  def validate(ssid, passphrase, country) do
    # not text at all: Python's AttributeError, an internal error rather than a 400
    if Py.truthy?(ssid) and not is_binary(ssid), do: raise("the network name is not text")
    if not Py.truthy?(ssid) or byte_size(ssid) > 32, do: raise(ArgumentError, "The network name must be 1 to 32 bytes.")

    if Py.truthy?(passphrase) and Py.len(passphrase) not in 8..63,
      do: raise(ArgumentError, "The passphrase must be 8 to 63 characters.")

    c = if Py.truthy?(country), do: country, else: "BE"

    if not (is_binary(c) and Regex.match?(~r/^[A-Za-z]{2}$/, c)),
      do: raise(ArgumentError, "The country must be two letters.")

    String.upcase(c)
  end

  @doc """
  Joins a network and saves it, or puts the old configuration back. `%{"ok" => true, "ip" => ...}` or
  `%{"ok" => false, "reason" => ...}`; raises ArgumentError on a bad request.
  """
  def connect(ssid, passphrase, hidden, country) do
    country = validate(ssid, passphrase, country)
    passphrase = passphrase || ""

    cond do
      hotspot_active?() ->
        # The radio is the setup hotspot's. The hotspot daemon lets go of it and tries this network (with
        # this very function, once wlan0 is a client again); the answer comes on the next page load.
        hotspot_join_request(ssid, passphrase, hidden, country)
        %{"ok" => false, "reason" => "hotspot_handover", "pending" => true}

      not ensure_wifi()["ok"] ->
        %{"ok" => false, "reason" => "supplicant_failed"}

      true ->
        do_connect(ssid, passphrase, hidden, country)
    end
  end

  defp do_connect(ssid, passphrase, hidden, country) do
    old_text = Sys.read(@wpa_conf)
    {_old_country, nets} = parse_wpa()
    sh = hexify(ssid)
    prio = Enum.max([0 | Enum.map(nets, & &1["prio"])]) + 1
    psk = if passphrase != "", do: hexify(:crypto.pbkdf2_hmac(:sha, passphrase, ssid, 4096, 32)), else: nil

    nets =
      Enum.reject(nets, &(&1["ssid"] == sh)) ++
        [%{"ssid" => sh, "psk" => psk, "hidden" => Py.truthy?(hidden), "prio" => prio}]

    write_wpa(country, nets)
    # iw may be absent; wpa_supplicant sets it too
    Sys.run(["iw", "reg", "set", country])
    wpa(["reconfigure"])
    deadline = now() + s(40)

    case join_wait(ssid, deadline, MapSet.new()) do
      :ok ->
        %{"ok" => true, "ip" => wlan_ip()}

      {:failed, saw} ->
        # Put the old configuration back: a failed attempt must not cost the working one.
        if old_text != "", do: AlnaslSetup.Server.Box.write_private(@wpa_conf, old_text, follow: true)
        wpa(["reconfigure"])

        reason =
          cond do
            "4WAY_HANDSHAKE" in saw or "GROUP_HANDSHAKE" in saw -> "wrong_passphrase"
            "ASSOCIATING" in saw or "ASSOCIATED" in saw or "AUTHENTICATING" in saw -> "rejected"
            true -> "not_found"
          end

        %{"ok" => false, "reason" => reason}
    end
  end

  defp join_wait(ssid, deadline, saw) do
    if now() >= deadline do
      {:failed, saw}
    else
      Py.nap(1.5)
      st = Diag.kv(elem(wpa(["status"]), 1))
      state = Map.get(st, "wpa_state", "")
      saw = MapSet.put(saw, state)

      # associated; an address may still be on its way
      if state == "COMPLETED" and wpa_unescape(Map.get(st, "ssid", "")) == ssid and
           (wlan_ip() != nil or now() > deadline - s(20)),
         do: :ok,
         else: join_wait(ssid, deadline, saw)
    end
  end

  def forget(ssid) do
    {country, nets} = parse_wpa()
    sh = hexify(ssid)
    write_wpa(country, Enum.reject(nets, &(&1["ssid"] == sh)))
    wpa(["reconfigure"])
    %{"ok" => true}
  end

  def set_country(country) do
    if not (is_binary(country) and Regex.match?(~r/^[A-Za-z]{2}$/, country)),
      do: raise(ArgumentError, "The country must be two letters.")

    {_c, nets} = parse_wpa()
    write_wpa(String.upcase(country), nets)
    wpa(["reconfigure"])
    %{"ok" => true}
  end

  # -------------------------------------------------------------------------------- hotspot --

  @doc """
  Hands a network to the hotspot daemon. 0600 in a root-only /run directory; it reads and deletes it
  within a few seconds. Not logged, not kept.
  """
  def hotspot_join_request(ssid, passphrase, hidden, country) do
    dir = Sys.path(@hotspot_run)

    if not File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    data =
      Json.encode(%{
        "ssid" => ssid,
        "passphrase" => passphrase || "",
        "hidden" => Py.truthy?(hidden),
        "country" => country
      })

    AlnaslSetup.Server.Box.write_private(@hotspot_join, data)
    Py.log("a Wi-Fi network was handed to the hotspot daemon to try")
  end

  @doc """
  While the AP is up: a scan in AP mode if the chip allows it (brcmfmac often does not), otherwise the
  list the hotspot daemon saved just before it took the radio.
  """
  def hotspot_scan do
    nets =
      if Diag.have?("iw") do
        case Diag.runo(["iw", "dev", "wlan0", "scan", "ap-force"], 15) do
          {0, out} -> Enum.reject(parse_iw_scan(out), &String.starts_with?(&1["ssid"], "Alnasl-setup-"))
          _ -> []
        end
      else
        []
      end

    {nets, source, age} =
      if nets != [] do
        {nets, "iw-ap", 0}
      else
        case Json.decode_or_nil(Sys.read(@hotspot_scan, "{}")) do
          %{} = c ->
            t = Py.float(Map.get(c, "t", 0)) || 0.0
            {Map.get(c, "networks") || [], "cached", trunc(Sys.now() - t)}

          _ ->
            {[], "cached", 0}
        end
      end

    saved = saved_names()

    nets =
      nets
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and is_binary(&1["ssid"])))
      |> Enum.sort_by(&(-Py.int!(Map.get(&1, "signal", -100))))
      |> Enum.map(&Map.put(&1, "saved", MapSet.member?(saved, &1["ssid"])))

    res = %{"available" => true, "networks" => nets, "source" => source, "age" => age, "hotspot" => true}
    if nets == [], do: Map.put(res, "reason", "no_results"), else: res
  end
end
