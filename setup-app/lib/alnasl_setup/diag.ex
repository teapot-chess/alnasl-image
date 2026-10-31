defmodule AlnaslSetup.Diag do
  @moduledoc """
  Diagnostics for the Alnasl hall box (was diag.py).

  Collects what is needed to answer "does the Wi-Fi work at all, and if not, where does it stop" plus
  the network, the services, the kiosk and the last journal lines, and can write all of it to one text
  file on the FAT boot partition so it can be read on any PC.

  Secrets never leave this module: every piece of text goes through `redact/1` before it is returned or
  written, and the Wi-Fi configuration is never dumped raw (only a summary: SSIDs, country, secured
  yes/no, from `AlnaslSetup.Wifi.summary/0`).
  """
  alias AlnaslSetup.{Json, Sys}
  alias AlnaslSetup.Server.Py

  @boot_efi "/boot/efi"
  @wpa_dir "/run/wpa_supplicant"
  @kiosk_run "/run/alnasl-kiosk"
  # written by /usr/local/sbin/alnasl-os-update
  @os_update_dir "/var/lib/alnasl-os-update"

  # {unit, extra journalctl selector}
  @journal_units [
    {"alnasl-setup.service", []},
    {"alnasl-kiosk.service", []},
    {"alnasl.service", []},
    # v7: the role, every role's app, and the steps between docker and the screen
    {"alnasl-mode.service", []},
    {"arkab.service", []},
    {"polis.service", []},
    {"nunki.service", []},
    {"cups.service", []},
    {"alnasl-sound.service", []},
    {"containerd.service", []},
    {"alnasl-kiosk-load.service", []},
    {"alnasl-slot-check.service", []},
    {"wpa_supplicant@wlan0.service", ["-t", "wpa_supplicant"]},
    {"systemd-networkd.service", []},
    {"systemd-resolved.service", []},
    {"alnasl-wifi.service", []},
    {"docker.service", []},
    {"alnasl-os-update.service", []},
    {"alnasl-splash.service", []},
    {"alnasl-reset.service", []},
    # v7.2: the setup hotspot; a grey sign-in sheet is otherwise a mystery from here
    {"alnasl-hotspot.service", []},
    {"alnasl-hotspot-ap.service", []},
    {"alnasl-hotspot-dns.service", []},
    {"alnasl-portal.service", []}
  ]
  # v7: every role's units, not only Alnasl's: a box that is the wrong thing, or no thing, shows here
  @service_units ~w(alnasl.service alnasl-kiosk.service alnasl-setup.service wpa_supplicant@wlan0.service
                    systemd-networkd.service systemd-resolved.service docker.service alnasl-firewall.service
                    alnasl-os-update.timer alnasl-os-update.service alnasl-splash.service
                    getty@tty1.service getty@tty2.service getty@tty3.service systemd-logind.service) ++
                   ~w(alnasl-mode.service alnasl-update.path arkab.service arkab-update.path
                      polis.service polis-update.path cups.service nunki.service nunki-update.path
                      alnasl-sound.service containerd.service alnasl-kiosk-load.service alnasl-slot-check.service
                      alnasl-hotspot.service alnasl-hotspot-ap.service alnasl-hotspot-dns.service alnasl-portal.service)
  # the role as chosen (data partition; v6 wrote master/slave)
  @role_file "/var/lib/alnasl-setup/mode"
  # what alnasl-mode made of it this boot
  @role_run "/run/alnasl-mode"
  # the role whose units this slot last switched on
  @role_applied "/etc/alnasl/role-applied"
  @roles ~w(alnasl arkab polis nunki)

  def boot_efi, do: @boot_efi

  # ------------------------------------------------------------------------------------- redact --

  @secret_keys "(?:psk|passphrase|wpa_passphrase|password|sae_password|wep_key\\d?|private_key_passwd|identity|anonymous_identity|pairwise_psk|authkey|auth-key|auth_key|ts_authkey|tskey)"
  @redactions [
    # wpa_supplicant style "key=value" lines, quoted or not, also commented-out ones (#psk="clear")
    {"(?im)^(\\s*#?\\s*" <> @secret_keys <> "\\s*=).*$", "\\1<redacted>"},
    # the same inside a longer line: psk=..., passphrase: ..., --authkey=..., TS_AUTHKEY=...
    {"(?i)(\\b" <> @secret_keys <> "\\b\\s*[=:]\\s*)(\"[^\"\\n]*\"|\\S+)", "\\1<redacted>"},
    {"(?i)(--auth-?key[= ]+)\\S+", "\\1<redacted>"},
    {"(?i)\\btskey-[A-Za-z0-9_-]+", "tskey-<redacted>"},
    {"(?i)(login\\.tailscale\\.com/a/)\\S+", "\\1<redacted>"},
    # wpa_passphrase <ssid> <passphrase>
    {"(\\bwpa_passphrase\\s+(?:\"[^\"]*\"|\\S+)\\s+)(\"[^\"]*\"|\\S+)", "\\1<redacted>"},
    # a 256-bit key in hex (a PSK / PMK as wpa_supplicant stores it)
    {"\\b[0-9a-fA-F]{64}\\b", "<redacted-key>"}
  ]

  @doc "Every secret shape the box knows, replaced. Unicode-aware like Python's str patterns."
  def redact(text) do
    text = Json.scrub(text)

    Enum.reduce(@redactions, text, fn {rx, rep}, acc ->
      Regex.replace(Regex.compile!(rx, "u"), acc, rep)
    end)
  end

  # -------------------------------------------------------------------------------------- helpers --

  @doc "A file as text (invalid UTF-8 replaced, like errors=\"replace\"), or the default."
  def read(path, default \\ "") do
    case File.read(Sys.path(path)) do
      {:ok, d} -> Json.scrub(d)
      {:error, _} -> default
    end
  end

  @doc "stdout+stderr as text; never raises."
  def runo(cmd, timeout \\ 15) do
    {rc, out} = Sys.runo(cmd, timeout)
    {rc, Json.scrub(out)}
  end

  def block(cmd, timeout \\ 15, maxlines \\ 60, tail \\ true) do
    {rc, out} = runo(cmd, timeout)
    lines = out |> String.trim_trailing("\n") |> splitlines()

    lines =
      if length(lines) > maxlines do
        cut = length(lines) - maxlines

        if tail,
          do: ["... (#{cut} earlier lines cut)" | Enum.take(lines, -maxlines)],
          else: Enum.take(lines, maxlines) ++ ["... (#{cut} more lines cut)"]
      else
        lines
      end

    "$ " <> Enum.join(cmd, " ") <> if(rc != 0, do: "   [exit #{rc}]", else: "") <> "\n" <> Enum.join(lines, "\n")
  end

  def kernel_log do
    {rc, out} = runo(["dmesg"], 15)

    if rc != 0 or String.trim(out) == "" do
      {_rc, out} = runo(["journalctl", "-k", "-b", "--no-pager", "-o", "short-monotonic"], 20)
      out
    else
      out
    end
  end

  def grep_lines(text, pattern, limit \\ 40) do
    rx = Regex.compile!(pattern, "iu")
    text |> splitlines() |> Enum.filter(&Regex.match?(rx, &1)) |> Enum.take(-limit)
  end

  def wpa_cli(args), do: runo(["wpa_cli", "-p", @wpa_dir, "-i", "wlan0" | args], 8)

  def have?(cmd), do: Sys.have?(cmd)

  @doc "Python's str.splitlines (\\n, \\r\\n, \\r; no empty last element)."
  def splitlines(""), do: []
  def splitlines(text), do: text |> String.split(~r/\r\n|\n|\r/) |> drop_last_empty()

  defp drop_last_empty(l), do: if(List.last(l) == "", do: Enum.drop(l, -1), else: l)

  defp strip(s), do: String.trim(s)

  # (a Windows temporary root has backslashes, which a wildcard takes for escapes)
  defp glob(pattern) do
    root = String.replace(Sys.path("/"), "\\", "/")
    pre = String.trim_trailing(root, "/")

    Sys.path(pattern)
    |> String.replace("\\", "/")
    |> Path.wildcard()
    |> Enum.map(&String.replace_prefix(&1, pre, ""))
    |> Enum.sort()
  end

  # ------------------------------------------------------------------------------------- checks --

  @doc "The 'does the Wi-Fi work at all' questions, each true/false/nil + a detail."
  def wifi_checks(klog) do
    add = fn acc, id, ok, detail -> acc ++ [%{"id" => id, "ok" => ok, "detail" => detail}] end

    mods = for l <- splitlines(read("/proc/modules")), strip(l) != "", do: hd(String.split(l))
    loaded = Enum.filter(mods, &Regex.match?(~r/^(brcmfmac|brcmutil|cfg80211)/, &1))

    c =
      add.(
        [],
        "driver",
        "brcmfmac" in mods or Sys.dir?("/sys/module/brcmfmac"),
        "loaded: " <> if(loaded == [], do: "none of brcmfmac/brcmutil/cfg80211", else: Enum.join(loaded, ", "))
      )

    sdio =
      for d <- glob("/sys/bus/sdio/devices/*") do
        drv =
          if Sys.exists?(d <> "/driver"),
            do: Path.basename(Sys.realpath(Sys.path(d <> "/driver"))),
            else: "no driver bound"

        "#{Path.basename(d)} vendor=#{strip(read(d <> "/vendor"))} device=#{strip(read(d <> "/device"))} driver=#{drv}"
      end

    chip = Enum.any?(sdio, &String.contains?(&1, "0x02d0"))

    c =
      add.(
        c,
        "hardware",
        if(chip, do: true, else: Sys.exists?("/sys/class/net/wlan0/device")),
        if(sdio == [],
          do: "no SDIO device found (the Wi-Fi chip sits on the SDIO bus of the Pi 4)",
          else: Enum.join(sdio, "; ")
        )
      )

    fw =
      grep_lines(
        klog,
        "brcmf_c_preinit_dcmds: Firmware|brcmfmac.*(firmware|fw).*(fail|error|-2)|Direct firmware load for brcm.*failed",
        6
      )

    good = Enum.filter(fw, &String.contains?(&1, "Firmware:"))
    bad = Enum.reject(fw, &String.contains?(&1, "Firmware:"))
    after_bracket = fn l -> l |> String.split("] ", parts: 2) |> List.last() end

    c =
      cond do
        good != [] ->
          add.(c, "firmware", true, after_bracket.(List.last(good)))

        bad != [] ->
          add.(c, "firmware", false, after_bracket.(List.last(bad)))

        true ->
          add.(
            c,
            "firmware",
            nil,
            "no firmware line in the kernel log (the log may have scrolled; the interface below is the real proof)"
          )
      end

    wl = Sys.exists?("/sys/class/net/wlan0")

    c =
      add.(
        c,
        "interface",
        wl,
        "wlan0 exists" <> if(wl, do: " (a Wi-Fi interface only appears after the firmware was loaded)", else: "")
      )

    if wl do
      st = strip(read("/sys/class/net/wlan0/operstate"))
      flags = parse_hex(strip(read("/sys/class/net/wlan0/flags", "0x0")))
      up = Bitwise.band(flags, 1) == 1
      hex = "0x" <> String.downcase(Integer.to_string(flags, 16))
      c = add.(c, "link", up, "operstate=#{st}, flags=#{hex} (#{if up, do: "UP", else: "administratively DOWN"})")
      {_rc, out} = wpa_cli(["ping"])
      o = strip(out)
      add.(c, "supplicant", String.starts_with?(o, "PONG"), if(o != "", do: hd(splitlines(o)), else: "no answer"))
    else
      c |> add.("link", nil, "no interface") |> add.("supplicant", nil, "no interface")
    end
  end

  # int(text or "0x0", 16); what does not parse counts as 0 (Python raised there)
  defp parse_hex(s) do
    s = if s == "", do: "0x0", else: s
    s = s |> String.replace_prefix("0x", "") |> String.replace_prefix("0X", "")

    case Integer.parse(s, 16) do
      {n, ""} -> n
      _ -> 0
    end
  end

  def verdict(checks) do
    by = Map.new(checks, &{&1["id"], &1["ok"]})

    cond do
      Map.get(by, "driver") == false -> "no_driver"
      Map.get(by, "hardware") == false -> "no_hardware"
      Map.get(by, "firmware") == false -> "firmware"
      Map.get(by, "interface") == false -> "no_interface"
      Map.get(by, "link") == false -> "link_down"
      Map.get(by, "supplicant") == false -> "supplicant"
      true -> "ok"
    end
  end

  # ----------------------------------------------------------------------------------- sections --

  defp lines_or(list, none), do: if(list == [], do: none, else: Enum.join(list, "\n  "))

  def wifi_text(klog, wpa_summary, last_scan) do
    mods =
      read("/proc/modules")
      |> splitlines()
      |> Enum.filter(&Regex.match?(~r/^(brcm|cfg80211|mac80211|rfkill|libarc4)/, &1))

    fwdir = "/lib/firmware/brcm"

    files =
      ~w(brcmfmac43455-sdio.bin brcmfmac43455-sdio.clm_blob brcmfmac43455-sdio.txt brcmfmac43455-sdio.raspberrypi,4-model-b.txt)

    fwlines =
      Enum.map_join(files, "\n  ", fn f ->
        p = Path.join(fwdir, f)

        f <>
          ": " <>
          case File.stat(Sys.path(p)) do
            {:ok, %{size: n}} -> "present, #{n} bytes"
            _ -> "MISSING"
          end
      end)

    out = [
      "modules (name size users deps):\n  " <>
        lines_or(Enum.map(mods, &(&1 |> String.split() |> Enum.take(4) |> Enum.join(" "))), "none"),
      "kernel messages about the chip, firmware and regulatory domain:\n  " <>
        lines_or(grep_lines(klog, "brcm|cfg80211|regulatory|sdio|mmc1|wlan0|firmware", 40), "none found"),
      "firmware files:\n  " <>
        fwlines <>
        "\n  regulatory.db: " <> if(Sys.exists?("/lib/firmware/regulatory.db"), do: "present", else: "MISSING"),
      if(Sys.exists?("/dev/rfkill") or Sys.exists?("/sys/class/rfkill"),
        do: block(["rfkill", "list"]),
        else: "rfkill: this kernel was built without rfkill support (no /dev/rfkill), so nothing can block the radio."
      ),
      block(["ip", "-d", "link", "show", "wlan0"]),
      block(["ip", "addr", "show", "wlan0"]),
      "regulatory domain:\n  cfg80211 module parameter: #{or_text(strip(read("/sys/module/cfg80211/parameters/ieee80211_regdom")), "(unset)")}\n  configured country (wpa_supplicant conf): #{Map.get(wpa_summary, "country", "?")}"
    ]

    out =
      out ++
        if have?("iw"),
          do: [block(["iw", "reg", "get"]), block(["iw", "dev"]), block(["iw", "dev", "wlan0", "link"])],
          else: ["iw: not installed"]

    out =
      out ++
        [
          "wpa_supplicant:\n  unit: #{strip(elem(runo(["systemctl", "is-active", "wpa_supplicant@wlan0.service"]), 1))}\n  processes: #{or_text(strip(elem(runo(["pgrep", "-a", "wpa_supplicant"]), 1)), "none running")}"
        ] ++
        for a <- ["ping", "status", "list_networks"] do
          {_rc, o} = wpa_cli([a])
          "$ wpa_cli #{a}\n" <> String.trim_trailing(o)
        end

    out =
      out ++
        [
          "saved networks (SSIDs only, no keys):\n  " <> lines_or(Map.get(wpa_summary, "lines", []), "none"),
          "last Wi-Fi scan test:\n" <>
            or_text(last_scan, "  (not run since the box started; use the Test Wi-Fi scan button)")
        ]

    Enum.join(out, "\n\n")
  end

  defp or_text(s, alt) when s in [nil, ""], do: alt
  defp or_text(s, _), do: s

  def network_text do
    [
      block(["ip", "-br", "link"]),
      block(["ip", "-br", "addr"]),
      block(["ip", "route"]),
      block(["ip", "-6", "route"], 15, 20),
      "resolv.conf:\n  " <> (read("/etc/resolv.conf") |> splitlines() |> Enum.take(12) |> Enum.join("\n  ")),
      block(["resolvectl", "status"], 15, 40, false),
      block(["networkctl", "--no-pager", "list"]),
      block(["networkctl", "--no-pager", "status", "wlan0"], 15, 25, false),
      block(["networkctl", "--no-pager", "status", "eth0"], 15, 25, false)
    ]
    |> Enum.join("\n\n")
  end

  @doc "The nightly OS update: its last result, the packages it changed, the runs before it, the next one."
  def updates_text do
    changed = splitlines(read(@os_update_dir <> "/last-changes"))

    slot =
      case Regex.run(~r/(?:^|\s)alnasl\.slot=([AB])(?:\s|$)/, read("/proc/cmdline")) do
        [_, s] -> s
        _ -> "?"
      end

    rel =
      read("/etc/alnasl/image-release")
      |> splitlines()
      |> Enum.filter(&String.starts_with?(&1, "ALNASL_"))
      |> Enum.join(" ")

    grub =
      read("/boot/efi/alnasl/grubenv")
      |> splitlines()
      |> Enum.filter(&String.starts_with?(&1, "alnasl_"))
      |> Enum.join(" ")

    [
      "last OS update run:\n  " <>
        lines_or(
          read(@os_update_dir <> "/last-result") |> splitlines() |> Enum.take(20),
          "(none yet; it runs at night, between 03:00 and 05:00)"
        ),
      "packages changed by that run (#{length(changed)}):\n  " <> lines_or(Enum.take(changed, 60), "none"),
      "earlier runs (newest last):\n  " <>
        lines_or(read(@os_update_dir <> "/history") |> splitlines() |> Enum.take(-10), "none"),
      block(["systemctl", "list-timers", "--all", "--no-pager", "alnasl-os-update.timer"], 15, 5, false),
      # v6 A/B: the whole-system image updates (alnasl-system-update) and the data partition.
      "system image: #{or_text(rel, "(no image-release)")}, running from slot #{slot}",
      "boot environment (grub): " <> or_text(grub, "(none: not the A/B layout)"),
      "last system image update:\n  " <>
        lines_or(read(@os_update_dir <> "/system-last-result") |> splitlines() |> Enum.take(12), "(none yet)"),
      "earlier system image updates (newest last):\n  " <>
        lines_or(read(@os_update_dir <> "/system-history") |> splitlines() |> Enum.take(-10), "none"),
      "data partition: " <> or_text(strip(read("/run/alnasl-data/state")), "(no state: alnasl-data did not run)"),
      block(["df", "-h", "/", "/data", "/boot/efi"], 15, 5, false)
    ]
    |> Enum.join("\n\n")
  end

  def services_text do
    @service_units
    |> Enum.map(fn u ->
      {_rc, o} =
        runo([
          "systemctl",
          "show",
          "-p",
          "ActiveState",
          "-p",
          "SubState",
          "-p",
          "UnitFileState",
          "-p",
          "Result",
          "-p",
          "NRestarts",
          "-p",
          "ConditionResult",
          "-p",
          "LoadState",
          u
        ])

      d = kv(o)

      if Map.get(d, "LoadState") == "not-found" do
        String.pad_trailing(u, 34) <> " not installed"
      else
        # v7: a unit of another role is skipped by its condition, which is not the same as failed.
        cond_ =
          case Map.get(d, "ConditionResult", "") do
            "yes" -> "conditions met"
            "no" -> "SKIPPED (a condition was not met)"
            _ -> "not started this boot"
          end

        String.pad_trailing(u, 34) <>
          " #{Map.get(d, "ActiveState", "?")} (#{Map.get(d, "SubState", "?")}), #{or_text(Map.get(d, "UnitFileState"), "static/not found")}, result=#{Map.get(d, "Result", "?")}, restarts=#{Map.get(d, "NRestarts", "?")}, #{cond_}"
      end
    end)
    |> Enum.join("\n")
  end

  @doc "dict(l.split(\"=\", 1) for l in text.splitlines() if \"=\" in l)"
  def kv(text) do
    for l <- splitlines(text), String.contains?(l, "="), into: %{} do
      [k, v] = String.split(l, "=", parts: 2)
      {k, v}
    end
  end

  @doc """
  v7: what this box is: the stored choice, what alnasl-mode made of it this boot, what the slot applied.
  A box whose app never starts is most often a box that is not what its owner thinks it is.
  """
  def role_text do
    flags = Enum.filter(@roles, &Sys.exists?(Path.join(@role_run, &1)))

    [
      "role as chosen:     #{or_text(strip(read(@role_file)), "(no file: alnasl, the default)")}  (#{@role_file})",
      "role this boot:     #{or_text(strip(read(@role_run <> "/role")), "(none: alnasl-mode did not run)")}  (#{@role_run}/role)",
      "v6 word this boot:  #{or_text(strip(read(@role_run <> "/mode")), "-")}  (#{@role_run}/mode)",
      "role flags present: " <>
        if(flags == [], do: "NONE: every role's app is held back by its condition", else: Enum.join(flags, " ")),
      "units applied for:  #{or_text(strip(read(@role_applied)), "(none yet)")}  (#{@role_applied})",
      "alnasl-mode.txt:    " <>
        if(Sys.exists?(@boot_efi <> "/alnasl-mode.txt"), do: "waiting on the boot partition", else: "none"),
      "alnasl-mode, this boot:\n  " <>
        lines_or(
          splitlines(
            elem(runo(["journalctl", "-b", "-u", "alnasl-mode.service", "--no-pager", "-o", "cat", "-n", "30"], 15), 1)
          ),
          "(nothing)"
        ),
      "role requests to the setup server (last 10):\n  " <>
        lines_or(
          grep_lines(
            elem(
              runo(["journalctl", "-u", "alnasl-setup.service", "--no-pager", "-o", "short-iso", "-n", "20000"], 20),
              1
            ),
            "POST /api/mode|role switch:",
            10
          ),
          "none"
        )
    ]
    |> Enum.join("\n")
  end

  def kiosk_text(extra) do
    drm =
      for d <- glob("/sys/class/drm/card*-*") do
        first = List.first(splitlines(read(d <> "/modes"))) || "-"
        "#{Path.basename(d)}: #{strip(read(d <> "/status"))}, first mode #{first}"
      end

    ([
       "kiosk state file: " <> or_text(strip(read(@kiosk_run <> "/state")), "(none)")
     ] ++
       drm ++
       [
         "fb0: virtual_size=#{or_text(strip(read("/sys/class/graphics/fb0/virtual_size")), "none")} modes=#{or_text(strip(read("/sys/class/graphics/fb0/modes")), "none")}",
         "active virtual terminal: #{or_text(strip(read("/sys/class/tty/tty0/active")), "?")} (the kiosk holds tty1; consoles are on tty2 and tty3)",
         "browser heartbeat: " <> or_text(Map.get(extra, "ping"), "(none)"),
         "kiosk config: " <>
           Enum.join(String.split(read("/etc/alnasl/kiosk.conf")), " ") <>
           " | keyboard: " <> Enum.join(String.split(read("/etc/alnasl/keyboard.conf")), " "),
         "browser restart log (why the kiosk restarted the browser):\n  " <>
           lines_or(
             read(@kiosk_run <> "/reload.log") |> splitlines() |> Enum.take(-15),
             "no restart recorded since boot"
           ),
         block(["docker", "ps", "-a", "--format", "{{.Names}}  {{.Status}}  {{.Image}}"], 15, 10),
         "kiosk path/resolution lines from the journal:\n  " <>
           Enum.join(
             grep_lines(
               elem(
                 runo(["journalctl", "-u", "alnasl-kiosk.service", "-b", "--no-pager", "-o", "cat", "-n", "400"], 20),
                 1
               ),
               "kiosk: (path|X screen|fb0|connector|starting|container ended|browser)|path=",
               12
             ),
             "\n  "
           ),
         "power / memory events in the kernel log:\n  " <>
           lines_or(
             grep_lines(
               kernel_log(),
               "under-?voltage|throttl|out of memory|oom-kill|killed process|brcmf.*(timeout|error|fail)",
               15
             ),
             "none"
           ),
         block(["journalctl", "--list-boots", "--no-pager"], 15, 8)
       ])
    |> Enum.join("\n\n")
  end

  def journals do
    res =
      for {unit, extra} <- @journal_units do
        cmd =
          if extra == [],
            do: ["journalctl", "--no-pager", "-n", "60", "-o", "short-iso", "-u", unit],
            else: ["journalctl", "--no-pager", "-n", "60", "-o", "short-iso" | extra]

        {_rc, out} = runo(cmd, 20)

        %{
          "unit" => unit <> if(extra != [], do: " + syslog tag wpa_supplicant", else: ""),
          "text" => redact(String.trim_trailing(out, "\n"))
        }
      end

    {_rc, out} = runo(["dmesg"], 15)

    res ++
      [
        %{
          "unit" => "kernel (Wi-Fi, cfg80211, mmc)",
          "text" => redact(Enum.join(grep_lines(out, "brcm|cfg80211|mmc|sdio|wlan0|regulatory", 60), "\n"))
        }
      ]
  end

  def collect(wpa_summary, last_scan \\ "", extra \\ %{}) do
    extra = extra || %{}
    klog = kernel_log()
    checks = wifi_checks(klog)

    sections =
      [
        %{"id" => "wifi", "title" => "Wi-Fi hardware and driver", "text" => wifi_text(klog, wpa_summary, last_scan)},
        %{"id" => "network", "title" => "Network", "text" => network_text()},
        %{"id" => "role", "title" => "Role (what this box is)", "text" => role_text()},
        %{"id" => "services", "title" => "Services", "text" => services_text()},
        %{"id" => "kiosk", "title" => "Screen and kiosk", "text" => kiosk_text(extra)},
        %{"id" => "updates", "title" => "OS and system updates", "text" => updates_text()}
      ]
      |> Enum.map(&Map.update!(&1, "text", fn t -> redact(t) end))

    %{
      "generated" => Py.strftime("%Y-%m-%d %H:%M:%S %z"),
      "checks" => checks,
      "verdict" => verdict(checks),
      "sections" => sections
    }
  end

  @doc """
  One plain-text file with everything. `system` is a list of `{key, value}` in the order they are
  printed (a map works too, in key order).
  """
  def report_text(info, jl, system) do
    marks = %{true => "ok", false => "FAIL", nil => "?"}

    out =
      ["ALNASL HALL BOX DIAGNOSTICS", "generated: " <> info["generated"], ""] ++
        Enum.map(system, fn {k, v} -> String.pad_trailing(to_string(k) <> ":", 12) <> " " <> to_string(v) end) ++
        ["", "== WI-FI VERDICT: #{info["verdict"]} =="] ++
        Enum.map(info["checks"], fn c -> "  [#{marks[c["ok"]]}] #{String.pad_trailing(c["id"], 10)} #{c["detail"]}" end) ++
        Enum.flat_map(info["sections"], fn s -> ["", bar(), String.upcase(s["title"]), bar(), s["text"]] end) ++
        ["", bar(), "JOURNALS (last 60 lines each)", bar()] ++
        Enum.flat_map(jl, fn j -> ["", "--- " <> j["unit"] <> " ---", j["text"]] end)

    redact(Enum.join(out, "\n") <> "\n")
  end

  defp bar, do: String.duplicate("=", 70)

  @doc """
  Writes alnasl-diagnostics-YYYYMMDD-HHMMSS.txt to the FAT partition (CRLF: opens properly in Windows
  Notepad), fsyncs it and syncs. `boot` is a box path. `{:ok, name}` or `{:error, reason}`.
  """
  def save_report(text, boot \\ @boot_efi) do
    with :ok <- ensure_mounted(boot) do
      name = "alnasl-diagnostics-#{Py.strftime("%Y%m%d-%H%M%S")}.txt"
      data = text |> redact() |> String.replace("\n", "\r\n")

      case File.open(Sys.path(Path.join(boot, name)), [:write, :binary]) do
        {:ok, f} ->
          try do
            :ok = IO.binwrite(f, data)
            :ok = :file.sync(f)
          after
            File.close(f)
          end

          Sys.run(["sync"], timeout: 60)
          {:ok, name}

        {:error, reason} ->
          {:error, "#{:file.format_error(reason)}: '#{Path.join(boot, name)}'"}
      end
    end
  end

  defp ensure_mounted(@boot_efi = boot) do
    if mountpoint?(boot) do
      :ok
    else
      runo(["mount", boot], 15)

      if mountpoint?(boot),
        do: :ok,
        else: {:error, "The boot partition (#{boot}) is not mounted and could not be mounted."}
    end
  end

  defp ensure_mounted(_), do: :ok

  # os.path.ismount, from /proc/mounts (the second field of a line; octal escapes as the kernel writes them)
  defp mountpoint?(dir) do
    read("/proc/mounts")
    |> splitlines()
    |> Enum.any?(fn l ->
      case String.split(l, " ") do
        [_, mp | _] -> unescape_mount(mp) == dir
        _ -> false
      end
    end)
  end

  defp unescape_mount(s), do: Regex.replace(~r/\\([0-7]{3})/, s, fn _, o -> <<String.to_integer(o, 8)>> end)
end
