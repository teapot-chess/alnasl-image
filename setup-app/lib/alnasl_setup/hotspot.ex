defmodule AlnaslSetup.Hotspot do
  @moduledoc """
  Alnasl hall box: the setup hotspot (docs/captive-portal.md).

  A box with no screen, no keyboard and no network still has to be told which Wi-Fi to use. So when it
  has no network it opens its own Wi-Fi, "Alnasl-setup-XXXX" (WPA2, the password from alnasl-hotspot.txt
  on the boot partition), and a phone that joins it gets the setup page shown by its own captive-portal
  check. This daemon decides when that hotspot is on, and switches wlan0 between the two things it can
  be: a Wi-Fi client (wpa_supplicant) or the access point (hostapd). Never both: the Pi's chip does not do
  AP and client at once reliably, and we are not going to find out the hard way in a hall.

      ALNASL_SETUP_MODE=hotspot   the daemon (alnasl-hotspot.service), a supervised process
      ... eval 'AlnaslSetup.CLI.main()' -- hotspot --stop      put wlan0 back in client mode (the unit's ExecStopPost)
      ... eval 'AlnaslSetup.CLI.main()' -- hotspot --prepare   only the password file and the QR code

  When it is on (`decide/14`, tested by test/hotspot_test.exs):

    * the box has had no network (no Ethernet address, no Wi-Fi client connection) for 60 s after boot
      (5 min if it had one earlier this boot: a hall's router that reboots is not a reason to stop being
      a client): on, until the box gets a network;
    * the box is on Ethernet: on for the first 10 minutes after boot too (wlan0 has nothing else to do);
    * the box is a Wi-Fi client: off;
    * a join from the setup page failed: on again for at least 10 minutes, whatever else holds;
    * when the reason goes but a phone is still connected, it lingers up to 10 minutes;
    * with saved networks and no phone connected, it steps aside now and then (every 5 min, 2 after a
      network was lost) for 45 s so the supplicant can find a network that came back.

  The password is never logged, never put on a command line, and hostapd is given the derived key only.

  The daemon calls the setup server's functions in this very VM (the Python imported `server`): the Wi-Fi
  scan and connect, the saved networks and Arkab's pending join link. They live in `AlnaslSetup.Wifi` and
  `AlnaslSetup.Server`; the application environment key `:hotspot_server` names a module that answers
  instead (the tests), and `:hotspot_sleep` a `fn milliseconds -> any` instead of sleeping.
  """
  use GenServer
  alias AlnaslSetup.{Json, QR, Sys}

  @boot_file "/boot/efi/alnasl-hotspot.txt"
  @qr_file "/boot/efi/alnasl-hotspot-qr.png"
  @template "/usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt"
  @state_dir "/var/lib/alnasl-setup"
  # a hash of (SSID, password): never the password itself
  @qr_stamp @state_dir <> "/hotspot-qr.stamp"
  @run "/run/alnasl-hotspot"
  # exists while the AP is up; the firewall and the setup server read it
  @active @run <> "/active"
  # no secrets: what the setup server and the screen show
  @status @run <> "/status.json"
  # written by the setup server (0600), read and deleted at once here
  @join_req @run <> "/join.json"
  # the last client-mode scan, for the page while the AP is up
  @scan_cache @run <> "/scan.json"
  @hostapd_conf @run <> "/hostapd.conf"
  @net_file "/run/systemd/network/05-alnasl-hotspot.network"
  @iface "wlan0"
  @ap_addr "10.42.0.1"
  @ssid_prefix "Alnasl-setup-"
  # No 0/O/o, 1/l/I: a password read off a sticker in a dim hall should not be a vision test.
  @alphabet ~c"ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
  @password_len 10

  # s after boot before the first decision (a saved network gets this long)
  @boot_grace 60
  # s after boot the hotspot stays on beside Ethernet
  @eth_window 600
  # s without network before the hotspot, when there was one earlier this boot
  @regrace 300
  # s the hotspot stays on after a failed join from the page
  @hold_after_fail 600
  # s a connected phone keeps it on after the reason went
  @linger 600
  # s between steps aside (saved networks, no phone)
  @probe_every 300
  # the same, after a network was lost
  @probe_every_lost 120
  # s a step aside lasts
  @probe_for 45
  # s for an address after the association, on top of the 40 of the Wi-Fi connect
  @join_extra 15
  @tick 3

  defstruct ap_on: false,
            ssid: nil,
            password: nil,
            enabled: true,
            boot: 0.0,
            no_net_since: 0.0,
            had_network: false,
            off_since: nil,
            hold_until: 0.0,
            last_probe: 0.0,
            fail_until: 0.0,
            reason: "starting",
            last_join: nil

  defp log(msg), do: Sys.log("alnasl-hotspot", msg)

  # ------------------------------------------------------------ the decision ---
  @doc """
  `{want_ap, probe, reason}`. Pure: every input is a number or a bool, every clock is `now`'s.

    * `no_net_since` - when the box last stopped having a network (or the boot)
    * `off_since`    - when the reason for the AP went while it was on (nil: not yet, so it is now)
    * `hold_until`   - a failed join keeps it on until then (0: no)
    * `last_probe`   - when the AP last came up or last stepped aside
  """
  def decide(
        now,
        uptime,
        has_wlan,
        enabled,
        eth_up,
        client_up,
        ap_on,
        saved,
        stations,
        no_net_since,
        had_network,
        off_since,
        hold_until,
        last_probe
      ) do
    cond do
      not has_wlan ->
        {false, false, "no_wlan"}

      not enabled ->
        {false, false, "disabled"}

      client_up ->
        {false, false, "wifi_client"}

      now < hold_until ->
        {true, false, "hold"}

      uptime < @boot_grace ->
        {false, false, "boot_grace"}

      true ->
        {policy, reason} =
          if eth_up do
            {uptime < @eth_window, "ethernet_window"}
          else
            grace = if had_network, do: @regrace, else: @boot_grace
            {now - no_net_since >= grace, "no_network"}
          end

        cond do
          not policy ->
            if ap_on and stations > 0 and (off_since == nil or now - off_since < @linger),
              do: {true, false, "linger"},
              else: {false, false, if(eth_up, do: "ethernet", else: "waiting")}

          ap_on and not eth_up and saved and stations == 0 and
              now - last_probe >= if(had_network, do: @probe_every_lost, else: @probe_every) ->
            {true, true, "probe"}

          true ->
            {true, false, reason}
        end
    end
  end

  # ------------------------------------------------------ the password file ---
  @doc "A password of `n` characters from the alphabet (no look-alikes), by the system's CSPRNG, without bias."
  def gen_password(n \\ @password_len) do
    k = length(@alphabet)
    limit = 256 - rem(256, k)
    alphabet = List.to_tuple(@alphabet)
    List.to_string(random_chars(n, k, limit, alphabet, []))
  end

  # Rejection sampling: a byte at or above `limit` would favour the first characters, so it is thrown away.
  defp random_chars(0, _k, _limit, _alphabet, acc), do: acc

  defp random_chars(n, k, limit, alphabet, acc) do
    bytes = for <<b <- :crypto.strong_rand_bytes(max(n * 2, 8))>>, b < limit, do: elem(alphabet, rem(b, k))
    take = Enum.take(bytes, n)
    random_chars(n - length(take), k, limit, alphabet, take ++ acc)
  end

  @doc "WPA2's rule for a passphrase: 8 to 63 printable ASCII characters."
  def valid_password?(p) when is_binary(p),
    do: byte_size(p) in 8..63 and Enum.all?(:binary.bin_to_list(p), &(&1 in 32..126))

  def valid_password?(_), do: false

  @doc "Alias of `valid_password?/1` (the Python's name)."
  def valid_password(p), do: valid_password?(p)

  @doc ~s(`%{"password" => binary | nil, "hotspot" => "auto" | "off"}` from the file's lines. The first PASSWORD= and HOTSPOT= lines count.)
  def parse_file(text) do
    {out, _seen} =
      text
      |> splitlines()
      |> Enum.reduce({%{"password" => nil, "hotspot" => "auto"}, MapSet.new()}, fn line, {out, seen} ->
        Enum.reduce(["PASSWORD", "HOTSPOT"], {out, seen}, fn key, {out, seen} ->
          if String.starts_with?(line, key <> "=") and not MapSet.member?(seen, key) do
            v = binary_part(line, byte_size(key) + 1, byte_size(line) - byte_size(key) - 1)

            out =
              if key == "PASSWORD" do
                Map.put(out, "password", v)
              else
                off = String.downcase(String.trim(v)) in ["off", "uit", "no", "nee", "0"]
                Map.put(out, "hotspot", if(off, do: "off", else: "auto"))
              end

            {out, MapSet.put(seen, key)}
          else
            {out, seen}
          end
        end)
      end)

    out
  end

  # Python's str.splitlines (without the trailing empty piece), then rstrip("\r") as the callers did.
  defp splitlines(text) do
    pieces = String.split(text, ~r/\r\n|[\n\r\x0b\x0c\x1c-\x1e\x{85}\x{2028}\x{2029}]/u)
    pieces = if List.last(pieces) == "", do: Enum.drop(pieces, -1), else: pieces
    Enum.map(pieces, &String.trim_trailing(&1, "\r"))
  end

  @doc """
  The file with its PASSWORD= and SSID= lines filled in and the box's status line at the end.
  Everything else (the header, the user's own lines) is kept as it was. CRLF, for the PC.
  """
  def render_file(text, password, ssid, note \\ nil) do
    {out, have_pw, have_ssid} =
      text
      |> splitlines()
      |> Enum.reduce({[], false, false}, fn line, {out, have_pw, have_ssid} ->
        cond do
          String.starts_with?(line, "PASSWORD=") and not have_pw ->
            {["PASSWORD=" <> password | out], true, have_ssid}

          String.starts_with?(line, "SSID=") ->
            if have_ssid, do: {out, have_pw, have_ssid}, else: {["SSID=" <> (ssid || "") | out], have_pw, true}

          # the new status line replaces the old one
          String.starts_with?(line, "# Box:") and note not in [nil, ""] ->
            {out, have_pw, have_ssid}

          true ->
            {[line | out], have_pw, have_ssid}
        end
      end)

    out = out |> Enum.drop_while(&(&1 == ""))
    out = if have_pw, do: out, else: ["PASSWORD=" <> password | out]
    out = if have_ssid, do: out, else: ["SSID=" <> (ssid || "") | out]
    out = if note not in [nil, ""], do: ["# Box: " <> note | out], else: out
    (out |> Enum.reverse() |> Enum.join("\r\n")) <> "\r\n"
  end

  def ssid_for(mac) do
    hexs = String.replace(mac || "", ~r/[^0-9A-Fa-f]/, "")
    @ssid_prefix <> if(String.length(hexs) >= 4, do: hexs |> String.slice(-4, 4) |> String.upcase(), else: "0000")
  end

  @doc "WPA2's pre-shared key from the passphrase: PBKDF2-HMAC-SHA1, 4096 rounds, 32 bytes, as hex."
  def psk_hex(ssid, password), do: :crypto.pbkdf2_hmac(:sha, password, ssid, 4096, 32) |> Base.encode16(case: :lower)

  def qr_stamp(ssid, password) do
    :crypto.hash(:sha256, "alnasl-hotspot-qr\0#{ssid}\0#{password}") |> Base.encode16(case: :lower)
  end

  # Whole file, then moved over the old one, then synced: a FAT partition and a pulled plug.
  defp write_fat(path, data) do
    real = Sys.path(path)
    tmp = real <> ".new"
    File.mkdir_p!(Path.dirname(real))
    f = File.open!(tmp, [:write, :binary])

    try do
      IO.binwrite(f, data)
      :ok = :file.sync(f)
    after
      File.close(f)
    end

    File.rename!(tmp, real)
    # the tests run on a PC too, which may not have a sync command
    Sys.run(["sync"], timeout: 60)
    :ok
  end

  @doc """
  Makes sure the file exists and holds a valid password (generated and written back when it is
  empty or not valid), that its SSID line is this box's, and that the QR code matches. Returns
  `{password, settings}`. Raises (File.Error and friends) only when nothing can be written at all.
  """
  def prepare(
        ssid,
        boot_file \\ @boot_file,
        qr_file \\ @qr_file,
        template \\ @template,
        stamp_file \\ @qr_stamp,
        note \\ nil
      ) do
    boot_exists = File.exists?(Sys.path(boot_file))

    text =
      case File.read(Sys.path(boot_file)) do
        {:ok, t} ->
          String.replace_invalid(t)

        {:error, _} ->
          t =
            case File.read(Sys.path(template)) do
              {:ok, t} -> t
              {:error, _} -> "# Alnasl setup hotspot / Alnasl-installatiehotspot\r\nPASSWORD=\r\nSSID=\r\n"
            end

          log("#{boot_file} was missing; made again from the image's copy")
          t
      end

    st = parse_file(text)
    pw = st["password"] || ""
    pw_stripped = String.trim(pw)
    # a trailing space from a text editor is nobody's intention
    pw = if pw_stripped != pw and valid_password?(pw_stripped), do: pw_stripped, else: pw

    {pw, changed_note} =
      cond do
        pw == "" ->
          log("generated a hotspot password (it is in #{boot_file}, not here)")
          {gen_password(), note || "a password was generated, because PASSWORD= was empty"}

        not valid_password?(pw) ->
          log("the hotspot password in #{boot_file} was not valid (8-63 printable ASCII); a new one was generated")
          {gen_password(), "the PASSWORD you wrote was not 8 to 63 plain characters; the box chose this one instead"}

        true ->
          {pw, note}
      end

    new = render_file(text, pw, ssid, changed_note)

    if String.replace(new, "\r\n", "\n") != String.replace(text, "\r\n", "\n") or not boot_exists,
      do: write_fat(boot_file, new)

    if ssid, do: write_qr(ssid, pw, qr_file, stamp_file)
    {pw, st}
  end

  defp write_qr(ssid, pw, qr_file, stamp_file) do
    stamp = qr_stamp(ssid, pw)

    old =
      stamp_file |> Sys.path() |> File.read() |> then(fn {_, v} -> if is_binary(v), do: String.trim(v), else: "" end)

    if old != stamp or not File.exists?(Sys.path(qr_file)) do
      write_fat(qr_file, QR.wifi_png(ssid, pw))
      File.mkdir_p!(Path.dirname(Sys.path(stamp_file)))
      File.write!(Sys.path(stamp_file), stamp <> "\n")
      log("wrote the join QR code for #{ssid} to #{qr_file}")
    end
  end

  @doc "WPA2-PSK (CCMP), never open. The key is the derived PSK, so the passphrase is not in it."
  def hostapd_conf(ssid, password, country) do
    unless valid_password?(password),
      do: raise(ArgumentError, "no valid password: no hotspot (an open one is not an option)")

    country = if is_binary(country) and Regex.match?(~r/\A[A-Z]{2}\z/, country), do: country, else: "BE"

    Enum.join(
      [
        "interface=" <> @iface,
        "driver=nl80211",
        "ctrl_interface=" <> @run <> "/hostapd",
        "ctrl_interface_group=0",
        "ssid=" <> ssid,
        "utf8_ssid=1",
        "country_code=" <> country,
        "ieee80211d=1",
        "hw_mode=g",
        "channel=6",
        "ieee80211n=1",
        "wmm_enabled=1",
        "max_num_sta=8",
        "auth_algs=1",
        "ignore_broadcast_ssid=0",
        "wpa=2",
        "wpa_key_mgmt=WPA-PSK",
        "wpa_pairwise=CCMP",
        "rsn_pairwise=CCMP",
        "wpa_psk=" <> psk_hex(ssid, password),
        "logger_stdout=-1",
        "logger_stdout_level=2",
        "logger_syslog=0"
      ],
      "\n"
    ) <> "\n"
  end

  @doc "networkd's file that gives wlan0 its address while the hotspot is on."
  def network_file do
    """
    # Written by alnasl-hotspot while the setup hotspot is on; removed when it goes off.
    [Match]
    Name=#{@iface}

    [Network]
    Address=#{@ap_addr}/24
    DHCP=no
    LinkLocalAddressing=no
    IPv6AcceptRA=no
    MulticastDNS=no
    ConfigureWithoutCarrier=yes

    [Link]
    RequiredForOnline=no
    """
  end

  # ---------------------------------------------------------- the box itself ---
  # Python's run(): stdout and stderr together, {127, reason} for a missing binary or a timeout.
  defp run(argv, timeout \\ 30), do: Sys.run(argv, timeout: timeout, stderr: :merge)
  defp sysctl(args), do: run(["systemctl" | args], 90)
  defp exists?(path), do: File.exists?(Sys.path(path))

  defp sleep(ms) do
    case Application.get_env(:alnasl_setup, :hotspot_sleep) do
      nil -> Process.sleep(ms)
      fun -> fun.(ms)
    end
  end

  defp ipv4(iface) do
    {_rc, out} = run(["ip", "-j", "-4", "addr", "show", "dev", iface], 10)

    with [first | _] <- Json.decode_or_nil(out),
         addrs when is_list(addrs) <- first["addr_info"] do
      for a <- addrs, is_map(a), a["scope"] == "global", do: a["local"]
    else
      _ -> []
    end
  end

  @doc false
  def eth_up? do
    case File.ls(Sys.path("/sys/class/net")) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.any?(fn n ->
          String.starts_with?(n, "e") and String.trim(Sys.read("/sys/class/net/#{n}/carrier")) == "1" and ipv4(n) != []
        end)

      {:error, _} ->
        false
    end
  end

  @doc false
  def client_up? do
    {_rc, out} = run(["wpa_cli", "-p", "/run/wpa_supplicant", "-i", @iface, "status"], 10)
    String.contains?(out, "wpa_state=COMPLETED") and Enum.any?(ipv4(@iface), &(not in_ap_net?(&1)))
  end

  defp in_ap_net?(addr) do
    case :inet.parse_ipv4_address(String.to_charlist(addr)) do
      {:ok, {10, 42, 0, _}} -> true
      _ -> false
    end
  end

  @doc false
  def stations do
    case run(["iw", "dev", @iface, "station", "dump"], 10) do
      {0, out} -> length(Regex.scan(~r/^Station /m, out))
      _ -> 0
    end
  end

  defp ensure_run_dir do
    dir = Sys.path(@run)

    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod(dir, 0o700)
    end
  end

  defp write_status(map) do
    ensure_run_dir()
    path = Sys.path(@status)
    File.write!(path <> ".new", Json.encode(map))
    File.rename!(path <> ".new", path)
  end

  # --- the setup server's functions, in this VM ---
  defp srv(fun, args \\ []) do
    case Application.get_env(:alnasl_setup, :hotspot_server) do
      nil -> real_srv(fun, args)
      mod -> apply(mod, fun, args)
    end
  end

  defp real_srv(:scan, []), do: AlnaslSetup.Wifi.scan()
  defp real_srv(:connect, [a, b, c, d]), do: AlnaslSetup.Wifi.connect(a, b, c, d)
  defp real_srv(:parse_wpa, []), do: AlnaslSetup.Wifi.parse_wpa()
  defp real_srv(:write_wpa, [a, b]), do: AlnaslSetup.Wifi.write_wpa(a, b)
  defp real_srv(:wlan_ip, []), do: AlnaslSetup.Wifi.wlan_ip()
  defp real_srv(:wpa_conf, []), do: AlnaslSetup.Wifi.wpa_conf()
  defp real_srv(:arkab_join_pending, []), do: AlnaslSetup.Server.arkab_join_pending()
  defp real_srv(:arkab_pending_file, []), do: AlnaslSetup.Server.arkab_pending_file()

  # ------------------------------------------------------------------- state ---
  @doc "A fresh state: the boot time is from /proc/uptime, the run directory is made."
  def new_state do
    now = Sys.now()
    boot = now - Sys.uptime(0.0)
    ensure_run_dir()
    %__MODULE__{boot: boot, no_net_since: boot}
  end

  # -- wlan0, one way or the other ---------------------------------------------------------------
  @doc "Everything the AP needed, gone; the supplicant back. Safe to call any time. Returns the state."
  def client_mode(%__MODULE__{} = s) do
    File.rm(Sys.path(@active))
    run(["/usr/local/sbin/alnasl-firewall", "reload"], 60)

    for u <- ["alnasl-portal.service", "alnasl-hotspot-dns.service", "alnasl-hotspot-ap.service"],
        do: sysctl(["stop", u])

    if exists?(@net_file) do
      File.rm(Sys.path(@net_file))
      run(["networkctl", "reload"])
    end

    run(["ip", "-4", "addr", "flush", "dev", @iface], 10)
    run(["networkctl", "reconfigure", @iface])

    if exists?("/sys/class/net/" <> @iface) do
      unless exists?(srv(:wpa_conf)), do: srv(:write_wpa, ["BE", []])
      sysctl(["restart", "wpa_supplicant@#{@iface}.service"])
    end

    %{s | ap_on: false}
  end

  @doc """
  The supplicant stopped, the address, hostapd, then DNS/DHCP and the page, then the firewall opens
  53/67/80 on wlan0. `{true | false, state}`; false (and back to client mode) when any of it does not come up.
  """
  def ap_mode(%__MODULE__{} = s) do
    country = elem(srv(:parse_wpa), 0) || "BE"

    try do
      hostapd_conf(s.ssid, s.password, String.upcase(country))
    rescue
      e in ArgumentError ->
        log(Exception.message(e))
        {false, s}
    else
      conf -> bring_up(s, conf)
    end
  end

  defp bring_up(s, conf) do
    # A scan while the supplicant still has the radio: the page shows it while the AP has it.
    try do
      res = srv(:scan)
      File.write!(Sys.path(@scan_cache), Json.encode(%{"t" => Sys.now(), "networks" => Map.get(res, "networks", [])}))
    rescue
      e -> log("scan before the hotspot failed: #{inspect(e.__struct__)}")
    catch
      kind, _ -> log("scan before the hotspot failed: #{kind}")
    end

    sysctl(["stop", "wpa_supplicant@#{@iface}.service"])
    run(["pkill", "-x", "wpa_supplicant"])
    File.rm(Sys.path("/run/wpa_supplicant/" <> @iface))

    conf_path = Sys.path(@hostapd_conf)
    File.write!(conf_path <> ".new", "")
    File.chmod!(conf_path <> ".new", 0o600)
    File.write!(conf_path <> ".new", conf)
    File.rename!(conf_path <> ".new", conf_path)
    File.mkdir_p!(Path.dirname(Sys.path(@net_file)))
    File.write!(Sys.path(@net_file), network_file())
    run(["networkctl", "reload"])
    run(["ip", "link", "set", "dev", @iface, "up"], 10)
    sysctl(["restart", "alnasl-hotspot-ap.service"])
    ap_active? = fn -> String.trim(elem(sysctl(["is-active", "alnasl-hotspot-ap.service"]), 1)) == "active" end

    ok =
      Enum.reduce_while(1..20, false, fn _, _ ->
        sleep(1000)

        cond do
          not ap_active?.() ->
            {:cont, false}

          true ->
            run(["networkctl", "reconfigure", @iface])
            if @ap_addr in ipv4(@iface), do: {:halt, true}, else: {:cont, false}
        end
      end)

    ok =
      ok ||
        (
          # networkd being shy
          run(["ip", "addr", "replace", @ap_addr <> "/24", "dev", @iface], 10)
          @ap_addr in ipv4(@iface) and ap_active?.()
        )

    if ok do
      # Nothing from the hotspot is forwarded anywhere: no NAT, and not even routing (docker turns
      # forwarding on for its own bridge; this interface is not that).
      run(["sysctl", "-q", "-w", "net.ipv4.conf.#{@iface}.forwarding=0"], 10)

      for u <- ["alnasl-hotspot-dns.service", "alnasl-portal.service"] do
        if elem(sysctl(["restart", u]), 0) != 0, do: log("#{u} did not start; the hotspot goes without it")
      end

      File.write!(Sys.path(@active), "#{@iface} #{@ap_addr}\n")
      run(["/usr/local/sbin/alnasl-firewall", "reload"], 60)
      s = %{s | ap_on: true, last_probe: Sys.now()}
      log("hotspot #{s.ssid} is on (#{s.reason}); the setup page is http://#{@ap_addr}/")
      {true, s}
    else
      log("the access point did not come up (hostapd or the address); staying a Wi-Fi client")
      {false, client_mode(s)}
    end
  end

  # -- the page asked for a network ---------------------------------------------------------------
  # The request file is the setup server's (0600, in a root-only directory); a symlink in its place is
  # not followed (the Python opened it O_NOFOLLOW), and it is left where it is.
  @doc false
  def take_join do
    path = Sys.path(@join_req)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        req =
          case File.read(path) do
            {:ok, data} -> Json.decode_or_nil(data)
            _ -> nil
          end

        File.rm(path)
        if is_map(req) and truthy?(req["ssid"]), do: req, else: nil

      _ ->
        nil
    end
  end

  defp truthy?(v), do: v not in [nil, false, 0, 0.0, "", [], %{}]

  defp py_str(v) when is_binary(v), do: v
  defp py_str(nil), do: "None"
  defp py_str(v) when is_boolean(v), do: if(v, do: "True", else: "False")
  defp py_str(v) when is_number(v), do: to_string(v)
  defp py_str(v), do: inspect(v)

  defp join(%__MODULE__{} = s, req) do
    ssid = py_str(req["ssid"])
    log(~s(a network was chosen on the setup page: "#{ssid}"; the hotspot steps aside to try it))
    s = %{s | reason: "joining"}
    status(s)
    s = if s.ap_on, do: client_mode(s), else: s
    sleep(2000)
    passphrase = if truthy?(req["passphrase"]), do: py_str(req["passphrase"]), else: ""
    country = if truthy?(req["country"]), do: py_str(req["country"]), else: "BE"

    r =
      try do
        srv(:connect, [ssid, passphrase, truthy?(req["hidden"]), country])
      rescue
        e in ArgumentError -> %{"ok" => false, "reason" => "bad_request", "detail" => Exception.message(e)}
      end

    ip = if r["ok"], do: r["ip"], else: nil

    {r, ip} =
      if r["ok"] && !ip do
        ip =
          Enum.reduce_while(1..@join_extra, nil, fn _, _ ->
            sleep(1000)
            if ip = srv(:wlan_ip), do: {:halt, ip}, else: {:cont, nil}
          end)

        if ip, do: {r, ip}, else: {%{"ok" => false, "reason" => "no_address"}, nil}
      else
        {r, ip}
      end

    now = Sys.now()
    {:ok, host} = :inet.gethostname()
    host = to_string(host)

    s =
      if r["ok"] do
        log(~s|joined "#{ssid}" (#{ip}); the hotspot stays off|)

        s = %{
          s
          | last_join: %{"ok" => true, "ssid" => ssid, "ip" => ip, "host" => host, "at" => now},
            had_network: true
        }

        note(s, ~s(joined Wi-Fi "#{ssid}" on #{format_time(now)}: address #{ip}, name #{host}.local))
        s
      else
        reason = r["reason"] || "failed"
        log(~s|joining "#{ssid}" did not work (#{reason}); the hotspot comes back|)

        %{
          s
          | last_join: %{"ok" => false, "ssid" => ssid, "reason" => reason, "at" => now},
            hold_until: now + @hold_after_fail
        }
      end

    status(s)
    s
  end

  defp format_time(unix) do
    {{y, mo, d}, {h, mi, _}} = :calendar.system_time_to_local_time(trunc(unix), :second)
    p = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{y}-#{p.(mo)}-#{p.(d)} #{p.(h)}:#{p.(mi)}"
  end

  defp note(s, text) do
    prepare(s.ssid, @boot_file, @qr_file, @template, @qr_stamp, text)
  rescue
    e in File.Error -> log("could not write to the boot partition: #{Exception.message(e)}")
  end

  defp status(s) do
    write_status(%{
      "active" => s.ap_on,
      "ssid" => s.ssid,
      "reason" => s.reason,
      "address" => @ap_addr,
      "portal" => "http://#{@ap_addr}/",
      "last_join" => s.last_join,
      "enabled" => s.enabled,
      "updated" => Sys.now()
    })
  end

  # -- the loop -----------------------------------------------------------------------------------
  defp setup_identity(s) do
    mac = String.trim(Sys.read("/sys/class/net/#{@iface}/address"))
    s = %{s | ssid: if(mac != "", do: ssid_for(mac), else: nil)}

    try do
      {pw, st} = prepare(s.ssid)
      %{s | password: pw, enabled: st["hotspot"] != "off"}
    rescue
      e in File.Error ->
        log("the boot partition cannot be read or written (#{Exception.message(e)}); no hotspot")
        %{s | password: nil}
    end
  end

  @doc "What a start does before the first iteration: put wlan0 right if an earlier run left the AP up, find the identity."
  def startup(%__MODULE__{} = s) do
    s =
      if exists?(@active) or exists?(@net_file) do
        log("a hotspot of an earlier run was still up; put back to client mode first")
        client_mode(s)
      else
        s
      end

    setup_identity(s)
  end

  @doc """
  One pass of the daemon's loop. `{state, delay_ms}`: 0 after a join (look again at once), the 3 s tick
  otherwise. May take a while (a join, a step aside, the access point coming up).
  """
  def iterate(%__MODULE__{} = s) do
    now = Sys.now()
    uptime = now - s.boot

    case take_join() do
      req when is_map(req) ->
        {join(s, req), 0}

      nil ->
        has_wlan = exists?("/sys/class/net/" <> @iface) and s.password != nil
        s = if has_wlan and not truthy?(s.ssid), do: setup_identity(s), else: s
        e = eth_up?()
        c = if s.ap_on, do: false, else: client_up?()
        s = if e or c, do: hand_over_arkab(%{s | had_network: true, no_net_since: now}), else: s
        st = if s.ap_on, do: stations(), else: 0
        saved = elem(srv(:parse_wpa), 1) != []

        {want, probe, reason} =
          decide(
            now,
            uptime,
            has_wlan,
            s.enabled,
            e,
            c,
            s.ap_on,
            saved,
            st,
            s.no_net_since,
            s.had_network,
            s.off_since,
            s.hold_until,
            s.last_probe
          )

        s = %{s | off_since: if(reason == "linger", do: s.off_since || now, else: nil), reason: reason}

        s =
          cond do
            probe -> step_aside(s)
            want and not s.ap_on and now >= s.fail_until -> start_ap(s, now)
            not want and s.ap_on -> stop_ap(s, reason)
            true -> s
          end

        status(s)
        {s, @tick * 1000}
    end
  end

  # a join link from the page, waiting for a network
  defp hand_over_arkab(s) do
    if exists?(srv(:arkab_pending_file)) do
      try do
        if res = srv(:arkab_join_pending), do: note(s, "Arkab's join link from the setup page: #{res}")
      rescue
        # Arkab is a separate program; this loop is not its keeper
        ex -> log("handing the join link to Arkab failed: #{inspect(ex.__struct__)}")
      catch
        kind, _ -> log("handing the join link to Arkab failed: #{kind}")
      end
    end

    s
  end

  defp step_aside(s) do
    log("stepping aside for #{@probe_for} s so a saved network can be found")
    s = client_mode(s)

    found =
      Enum.reduce_while(1..div(@probe_for, @tick), false, fn _, _ ->
        sleep(@tick * 1000)
        if client_up?(), do: {:halt, true}, else: {:cont, false}
      end)

    s = %{s | last_probe: Sys.now()}

    if found do
      log("a saved network answered; the hotspot stays off")
      %{s | had_network: true, no_net_since: Sys.now()}
    else
      {_ok, s} = ap_mode(s)
      s
    end
  end

  defp start_ap(s, now) do
    case ap_mode(s) do
      {true, s} -> s
      {false, s} -> %{s | fail_until: now + 120}
    end
  end

  defp stop_ap(s, reason) do
    log("hotspot off (#{reason})")
    s = client_mode(s)
    %{s | off_since: nil}
  end

  # ------------------------------------------------------------------ process ---
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, new_state(), {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, s) do
    s = startup(s)
    Process.send_after(self(), :tick, 0)
    {:noreply, s}
  end

  @impl true
  def handle_info(:tick, s) do
    {s, delay} = iterate(s)
    Process.send_after(self(), :tick, delay)
    {:noreply, s}
  end

  def handle_info(_other, s), do: {:noreply, s}

  # --------------------------------------------------------------- command line ---
  @doc """
  `--prepare`: the password file and the QR code only. `--stop`: wlan0 back in client mode (the unit's
  ExecStopPost). Returns the exit code.
  """
  def main(argv) do
    Application.ensure_all_started(:crypto)

    cond do
      "--prepare" in argv ->
        mac = String.trim(Sys.read("/sys/class/net/#{@iface}/address"))

        try do
          prepare(if(mac != "", do: ssid_for(mac), else: nil))
          0
        rescue
          e in File.Error ->
            log("could not write to the boot partition: #{Exception.message(e)}")
            1
        end

      "--stop" in argv ->
        s = new_state()
        client_mode(s)

        write_status(%{
          "active" => false,
          "ssid" => nil,
          "reason" => "stopped",
          "address" => @ap_addr,
          "portal" => nil,
          "last_join" => nil,
          "enabled" => false,
          "updated" => Sys.now()
        })

        0

      true ->
        IO.puts(:stderr, "usage: hotspot --stop | --prepare   (the daemon is the alnasl-hotspot.service)")
        2
    end
  end
end
