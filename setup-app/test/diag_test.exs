defmodule AlnaslSetup.DiagTest do
  # Ported from scripts/test-diag.py: a fake wpa_supplicant configuration with a hashed psk, a clear
  # passphrase (also as a commented-out line) and an open network, plus a fake Tailscale auth key, fed
  # to every path that ends up in the diagnostics (summary, section texts, journals, saved file). No
  # secret may survive and no SSID may be lost. Plus the verdict, the report layout and the saved file.
  use ExUnit.Case, async: false
  alias AlnaslSetup.{Diag, Wifi}
  alias AlnaslSetup.Test.Box

  @psk "5f4dcc3b5aa765d61d8327deb882cf995f4dcc3b5aa765d61d8327deb882cf99"
  @clear "SuperSecretPassw0rd!"
  @tskey "tskey-auth-kABCDE12CNTRL-abcdefghijklmnop1234567890"
  @login "https://login.tailscale.com/a/1a2b3c4d5e6f"
  @secrets [@psk, @clear, @tskey, "1a2b3c4d5e6f"]

  @conf "ctrl_interface=/run/wpa_supplicant\nupdate_config=0\ncountry=BE\n" <>
          "network={\n\tssid=486f6d654e6574\n\tpsk=#{@psk}\n\tpriority=1\n}\n" <>
          "network={\n\tssid=\"Cafe Guest\"\n\t#psk=\"#{@clear}\"\n\tpsk=\"#{@clear}\"\n\tscan_ssid=1\n}\n" <>
          "network={\n\tssid=\"OpenNet\"\n\tkey_mgmt=NONE\n}\n"

  @blob "line one\npsk=#{@psk}\n\tpsk=\"#{@clear}\"\nkey #{@psk}\nlogin #{@login}\nwpa_passphrase HomeNet #{@clear}\nTS_AUTHKEY=#{@tskey}\nssid=486f6d654e6574\n"

  # every file the diagnostics read (Python's test stubbed diag.read for all of them)
  @read_paths ~w(/proc/modules /sys/module/cfg80211/parameters/ieee80211_regdom /etc/resolv.conf
                 /var/lib/alnasl-os-update/last-result /var/lib/alnasl-os-update/last-changes
                 /var/lib/alnasl-os-update/history /var/lib/alnasl-os-update/system-last-result
                 /var/lib/alnasl-os-update/system-history /proc/cmdline /etc/alnasl/image-release
                 /boot/efi/alnasl/grubenv /run/alnasl-data/state /var/lib/alnasl-setup/mode
                 /run/alnasl-mode/role /run/alnasl-mode/mode /etc/alnasl/role-applied /run/alnasl-kiosk/state
                 /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/modes /sys/class/tty/tty0/active
                 /etc/alnasl/kiosk.conf /etc/alnasl/keyboard.conf /run/alnasl-kiosk/reload.log)

  setup do
    Box.root!()
    Box.put(Wifi.wpa_conf(), @conf)
    :ok
  end

  defp leaked(text), do: Enum.filter(@secrets, &String.contains?(text, &1))

  describe "the Wi-Fi summary" do
    test "has no key material, lists the SSIDs and the country" do
      summ = Wifi.summary()
      stext = summ["country"] <> "\n" <> Enum.join(summ["lines"], "\n")
      assert leaked(stext) == []
      refute String.contains?(String.downcase(stext), "psk")
      assert stext =~ "HomeNet" and stext =~ "Cafe Guest" and stext =~ "OpenNet"
      assert summ["country"] == "BE"
      assert summ["lines"] == ["HomeNet  [secured]", "Cafe Guest  [secured, hidden]", "OpenNet  [open]"]
    end
  end

  describe "redact/1" do
    @samples [
      "psk=#{@psk}",
      "\tpsk=\"#{@clear}\"",
      "\t#psk=\"#{@clear}\"",
      "passphrase: #{@clear}",
      "PASSPHRASE=#{@clear}",
      "tailscale up --authkey=#{@tskey} --hostname=x",
      "tailscale up --auth-key #{@tskey}",
      "TS_AUTHKEY=#{@tskey}",
      "Visit #{@login} to log in",
      "key tskey-client-kXYZ-0123456789abcdef used",
      "wpa_passphrase HomeNet #{@clear}",
      "pmk #{@psk} derived",
      "sae_password=#{@clear}",
      "wep_key0=#{@clear}"
    ]

    for s <- @samples do
      test "removes the secret from #{inspect(String.slice(s, 0, 34))}" do
        assert leaked(Diag.redact(unquote(s))) == []
      end
    end

    test "keeps SSIDs, hex or quoted" do
      assert Diag.redact("ssid=486f6d654e6574") =~ "486f6d654e6574"
      assert Diag.redact("ssid=\"Cafe Guest\"") =~ "Cafe Guest"
    end

    test "exact replacements" do
      assert Diag.redact("\tpsk=\"#{@clear}\"") == "\tpsk=<redacted>"
      assert Diag.redact("pmk #{@psk} derived") == "pmk <redacted-key> derived"
      assert Diag.redact("tailscale up --auth-key #{@tskey}") =~ "--auth-key <redacted>"
      assert Diag.redact("Visit #{@login} to log in") == "Visit https://login.tailscale.com/a/<redacted> to log in"
      assert Diag.redact("key tskey-client-kXYZ-0123456789abcdef used") == "key tskey-<redacted> used"
    end
  end

  describe "the whole report, with every command and every file read answering with secrets" do
    setup do
      Box.runner!(fn _ -> {0, @blob} end)
      for p <- @read_paths, do: Box.put(p, @blob)
      :ok
    end

    test "no secret anywhere, SSIDs kept, six sections, known check ids" do
      summ = Wifi.summary()
      info = Diag.collect(summ, "last scan\n" <> @blob, %{"ping" => "x"})
      jl = Diag.journals()
      rep = Diag.report_text(info, jl, [{"hostname", "alnasl-test"}, {"note", @blob}])
      assert leaked(rep) == []
      assert rep =~ "HomeNet" and rep =~ "486f6d654e6574"
      assert Enum.all?(info["sections"], &(leaked(&1["text"]) == []))
      assert Enum.all?(jl, &(leaked(&1["text"]) == []))

      assert MapSet.new(info["sections"], & &1["id"]) ==
               MapSet.new(~w(wifi network role services kiosk updates))

      assert Enum.all?(info["checks"], &(&1["id"] in ~w(driver hardware firmware interface link supplicant)))
      assert info["generated"] =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}$/
      assert length(jl) == 25
      assert List.last(jl)["unit"] == "kernel (Wi-Fi, cfg80211, mmc)"
      assert Enum.at(jl, 12)["unit"] == "wpa_supplicant@wlan0.service + syslog tag wpa_supplicant"
    end

    test "the saved file has no secret and Windows line endings" do
      info = Diag.collect(Wifi.summary(), "", %{})
      rep = Diag.report_text(info, Diag.journals(), [{"hostname", "alnasl-test"}])
      File.mkdir_p!(AlnaslSetup.Sys.path("/bootdir"))
      assert {:ok, name} = Diag.save_report(rep, "/bootdir")
      assert name =~ ~r/^alnasl-diagnostics-\d{8}-\d{6}\.txt$/
      data = File.read!(AlnaslSetup.Sys.path("/bootdir/" <> name))
      assert leaked(data) == []
      assert data =~ "\r\n"
      refute data =~ ~r/[^\r]\n/
    end
  end

  describe "verdict/1" do
    defp checks(kv), do: Enum.map(kv, fn {id, ok} -> %{"id" => id, "ok" => ok, "detail" => ""} end)

    test "the first failing step, in order" do
      all_ok = for id <- ~w(driver hardware firmware interface link supplicant), do: {id, true}
      assert Diag.verdict(checks(all_ok)) == "ok"
      assert Diag.verdict(checks([{"driver", false}, {"hardware", false}])) == "no_driver"
      assert Diag.verdict(checks([{"driver", true}, {"hardware", false}, {"firmware", false}])) == "no_hardware"
      assert Diag.verdict(checks([{"firmware", false}, {"interface", false}])) == "firmware"
      assert Diag.verdict(checks([{"firmware", nil}, {"interface", false}])) == "no_interface"
      assert Diag.verdict(checks([{"interface", true}, {"link", false}, {"supplicant", false}])) == "link_down"
      assert Diag.verdict(checks([{"link", nil}, {"supplicant", false}])) == "supplicant"
      assert Diag.verdict(checks([{"link", nil}, {"supplicant", nil}])) == "ok"
    end
  end

  describe "report_text/3" do
    test "the layout" do
      info = %{
        "generated" => "2026-10-31 12:00:00 +0000",
        "verdict" => "ok",
        "checks" => [
          %{"id" => "driver", "ok" => true, "detail" => "loaded: brcmfmac"},
          %{"id" => "firmware", "ok" => nil, "detail" => "no line"},
          %{"id" => "link", "ok" => false, "detail" => "down"}
        ],
        "sections" => [%{"id" => "wifi", "title" => "Wi-Fi hardware and driver", "text" => "body"}]
      }

      jl = [%{"unit" => "alnasl.service", "text" => "j1"}]
      text = Diag.report_text(info, jl, [{"hostname", "box"}, {"uptime", "12 s"}])
      bar = String.duplicate("=", 70)

      assert text ==
               Enum.join(
                 [
                   "ALNASL HALL BOX DIAGNOSTICS",
                   "generated: 2026-10-31 12:00:00 +0000",
                   "",
                   "hostname:    box",
                   "uptime:      12 s",
                   "",
                   "== WI-FI VERDICT: ok ==",
                   "  [ok] driver     loaded: brcmfmac",
                   "  [?] firmware   no line",
                   "  [FAIL] link       down",
                   "",
                   bar,
                   "WI-FI HARDWARE AND DRIVER",
                   bar,
                   "body",
                   "",
                   bar,
                   "JOURNALS (last 60 lines each)",
                   bar,
                   "",
                   "--- alnasl.service ---",
                   "j1"
                 ],
                 "\n"
               ) <> "\n"
    end
  end

  describe "save_report/2 on the boot partition" do
    test "mounts /boot/efi when it is not a mountpoint, and refuses when it still is not" do
      Box.runner!(fn _ -> {32, "mount: failed\n"} end)
      Box.put("/proc/mounts", "/dev/root / ext4 rw 0 0\n")

      assert {:error, "The boot partition (/boot/efi) is not mounted and could not be mounted."} =
               Diag.save_report("x\n")

      assert ["mount", "/boot/efi"] in Box.ran()
    end

    test "writes straight away when /boot/efi is mounted" do
      Box.runner!(fn _ -> nil end)
      Box.put("/proc/mounts", "/dev/root / ext4 rw 0 0\n/dev/mmcblk0p1 /boot/efi vfat rw 0 0\n")
      File.mkdir_p!(AlnaslSetup.Sys.path("/boot/efi"))
      assert {:ok, name} = Diag.save_report("a\nb\n")
      assert File.read!(AlnaslSetup.Sys.path("/boot/efi/" <> name)) == "a\r\nb\r\n"
      refute ["mount", "/boot/efi"] in Box.ran()
      assert ["sync"] in Box.ran()
    end
  end

  describe "checks and helpers" do
    test "block/2 cuts long output and marks a failing exit" do
      Box.runner!(fn _ -> {1, Enum.map_join(1..70, "", &"l#{&1}\n")} end)
      out = Diag.block(["ip", "route"])
      assert out =~ ~r/^\$ ip route   \[exit 1\]\n\.\.\. \(10 earlier lines cut\)\nl11\n/
      out = Diag.block(["ip", "route"], 15, 5, false)
      assert out == "$ ip route   [exit 1]\nl1\nl2\nl3\nl4\nl5\n... (65 more lines cut)"
    end

    test "grep_lines/3 keeps the last hits, case-insensitively" do
      assert Diag.grep_lines("a BRCM 1\nb\nbrcm 2\nbrcm 3\n", "brcm", 2) == ["brcm 2", "brcm 3"]
    end

    test "wifi_checks without a chip or an interface" do
      Box.runner!(fn _ -> nil end)
      Box.put("/proc/modules", "cfg80211 1000 1 brcmfmac, Live 0x0\n")
      checks = Diag.wifi_checks("")
      by = Map.new(checks, &{&1["id"], &1})
      assert Enum.map(checks, & &1["id"]) == ~w(driver hardware firmware interface link supplicant)
      assert by["driver"]["ok"] == false
      assert by["driver"]["detail"] == "loaded: cfg80211"
      assert by["hardware"]["ok"] == false
      assert by["firmware"]["ok"] == nil
      assert by["interface"]["ok"] == false
      assert by["link"]["ok"] == nil and by["supplicant"]["detail"] == "no interface"
      assert Diag.verdict(checks) == "no_driver"
    end

    # an SDIO device name has colons, which a Windows file name cannot
    @tag :unix
    test "wifi_checks with a working chip" do
      Box.runner!(fn
        ["wpa_cli" | _] -> {0, "PONG\n"}
        _ -> nil
      end)

      Box.put("/proc/modules", "brcmfmac 1 0 - Live\nbrcmutil 1 1 brcmfmac, Live\n")
      Box.put("/sys/bus/sdio/devices/mmc1:0001:1/vendor", "0x02d0\n")
      Box.put("/sys/bus/sdio/devices/mmc1:0001:1/device", "0xa9a6\n")
      Box.put("/sys/class/net/wlan0/operstate", "up\n")
      Box.put("/sys/class/net/wlan0/flags", "0x1003\n")
      klog = "[    5.1] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4345/6 wl0: Jan  1 2026 version 7.45\n"
      by = Map.new(Diag.wifi_checks(klog), &{&1["id"], &1})
      assert by["driver"]["ok"] and by["hardware"]["ok"] and by["firmware"]["ok"]
      assert by["firmware"]["detail"] =~ ~r/^brcmfmac: brcmf_c_preinit_dcmds: Firmware/
      assert by["hardware"]["detail"] == "mmc1:0001:1 vendor=0x02d0 device=0xa9a6 driver=no driver bound"
      assert by["link"] == %{"id" => "link", "ok" => true, "detail" => "operstate=up, flags=0x1003 (UP)"}
      assert by["supplicant"] == %{"id" => "supplicant", "ok" => true, "detail" => "PONG"}
    end

    test "services_text: not installed, skipped by its condition" do
      Box.runner!(fn
        ["systemctl", "show" | rest] ->
          case List.last(rest) do
            "arkab.service" ->
              {0,
               "ActiveState=inactive\nSubState=dead\nUnitFileState=enabled\nResult=success\nNRestarts=0\nConditionResult=no\nLoadState=loaded\n"}

            _ ->
              {0, "LoadState=not-found\n"}
          end

        _ ->
          nil
      end)

      text = Diag.services_text()
      assert text =~ String.pad_trailing("alnasl.service", 34) <> " not installed"

      assert text =~
               String.pad_trailing("arkab.service", 34) <>
                 " inactive (dead), enabled, result=success, restarts=0, SKIPPED (a condition was not met)"
    end

    test "role_text says what the box is" do
      Box.runner!(fn _ -> nil end)
      Box.put("/var/lib/alnasl-setup/mode", "arkab\n")
      Box.put("/run/alnasl-mode/role", "arkab\n")
      Box.put("/run/alnasl-mode/arkab", "")
      text = Diag.role_text()
      assert text =~ "role as chosen:     arkab  (/var/lib/alnasl-setup/mode)"
      assert text =~ "role flags present: arkab"
      assert text =~ "units applied for:  (none yet)  (/etc/alnasl/role-applied)"
      assert text =~ "alnasl-mode.txt:    none"
      assert text =~ "role requests to the setup server (last 10):\n  none"
    end
  end
end
