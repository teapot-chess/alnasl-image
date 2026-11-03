defmodule AlnaslSetup.HotspotTest do
  # Port of scripts/test-hotspot.py (decide, the password file, hostapd) plus the daemon's iteration
  # against a fake box (fake root, fake commands, a stand-in for the setup server's functions).
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias AlnaslSetup.{Hotspot, Json, Sys}
  alias AlnaslSetup.Test.{Box, HotspotServer, QRDecoder}

  @template Path.expand("../../overlay/boot-efi/alnasl-hotspot.txt", __DIR__)

  @boot_file "/boot/efi/alnasl-hotspot.txt"
  @qr_file "/boot/efi/alnasl-hotspot-qr.png"
  @tpl "/usr/share/alnasl/defaults/boot-efi/alnasl-hotspot.txt"
  @stamp "/var/lib/alnasl-setup/hotspot-qr.stamp"

  # ------------------------------------------------------------------ decide ---
  defp d(opts) do
    o =
      Map.merge(
        %{
          now: 10_000.0,
          uptime: 1000.0,
          has_wlan: true,
          enabled: true,
          eth: false,
          client: false,
          ap_on: false,
          saved: false,
          stations: 0,
          no_net_since: nil,
          had_network: false,
          off_since: nil,
          hold_until: 0.0,
          last_probe: nil
        },
        Map.new(opts)
      )

    Hotspot.decide(
      o.now,
      o.uptime,
      o.has_wlan,
      o.enabled,
      o.eth,
      o.client,
      o.ap_on,
      o.saved,
      o.stations,
      o.no_net_since || o.now - o.uptime,
      o.had_network,
      o.off_since,
      o.hold_until,
      o.last_probe || o.now
    )
  end

  describe "decide/14" do
    test "(a) no network: not before 60 s, then on, and on" do
      assert {false, false, "boot_grace"} = d(uptime: 30)
      assert d(uptime: 61) == {true, false, "no_network"}
      assert {true, _, _} = d(uptime: 5000)
    end

    test "(b) Ethernet: on for the first 10 minutes, then off, lingering for a phone" do
      assert d(uptime: 61, eth: true) == {true, false, "ethernet_window"}
      assert {true, _, _} = d(uptime: 599, eth: true, ap_on: true)
      assert d(uptime: 601, eth: true, ap_on: true) == {false, false, "ethernet"}
      assert d(uptime: 601, eth: true, ap_on: true, stations: 1) == {true, false, "linger"}
      assert {true, _, _} = d(uptime: 601, eth: true, ap_on: true, stations: 1, off_since: 10_000.0 - 599)
      assert {false, _, _} = d(uptime: 601, eth: true, ap_on: true, stations: 1, off_since: 10_000.0 - 601)
      assert {false, _, _} = d(uptime: 601, eth: true, ap_on: false, stations: 1)
    end

    test "(c) a Wi-Fi client: off, phones or not" do
      assert d(client: true) == {false, false, "wifi_client"}
      assert {false, _, _} = d(client: true, ap_on: true, stations: 3)
    end

    test "a failed join holds it on" do
      assert d(uptime: 30, hold_until: 10_005.0) == {true, false, "hold"}
      assert {true, _, _} = d(eth: true, uptime: 5000, hold_until: 10_005.0)
      assert {false, _, _} = d(eth: true, uptime: 5000, hold_until: 9_999.0)
      assert {false, _, _} = d(client: true, hold_until: 10_005.0)
    end

    test "disabled, or no wlan0 (or no password)" do
      assert d(enabled: false) == {false, false, "disabled"}
      assert d(has_wlan: false) == {false, false, "no_wlan"}
    end

    test "a lost network: wait 5 minutes (the router may be rebooting)" do
      assert d(had_network: true, no_net_since: 10_000.0 - 100) == {false, false, "waiting"}
      assert {true, _, _} = d(had_network: true, no_net_since: 10_000.0 - 301)
    end

    test "steps aside for saved networks when nobody is on it" do
      assert d(ap_on: true, saved: true, last_probe: 10_000.0 - 301) == {true, true, "probe"}
      assert {_, false, _} = d(ap_on: true, saved: true, last_probe: 10_000.0 - 200)

      assert {_, true, _} =
               d(ap_on: true, saved: true, had_network: true, no_net_since: 9_000.0, last_probe: 10_000.0 - 121)

      assert {_, false, _} = d(ap_on: true, saved: true, stations: 1, last_probe: 0.0)
      assert {_, false, _} = d(ap_on: true, saved: false, last_probe: 0.0)
      assert {_, false, _} = d(ap_on: true, saved: true, eth: true, uptime: 200, last_probe: 0.0)
    end

    # Ten minutes of a box on Ethernet, with a phone that arrives late, through the daemon's own bookkeeping.
    defp simulate(eth, phone_from, until) do
      0..(until - 1)//3
      |> Enum.reduce({false, nil, []}, fn t, {ap, off_since, timeline} ->
        st = if ap and phone_from != nil and t >= phone_from, do: 1, else: 0

        {want, _probe, reason} =
          Hotspot.decide(1.0e6 + t, t * 1.0, true, true, eth, false, ap, false, st, 1.0e6, false, off_since, 0.0, 1.0e6)

        off_since = if reason == "linger", do: off_since || 1.0e6 + t, else: nil
        {want, off_since, if(want != ap, do: [{t, want, reason} | timeline], else: timeline)}
      end)
      |> then(fn {_, _, tl} -> Enum.reverse(tl) end)
    end

    test "Ethernet run: on at ~60 s, off at ~600 s" do
      assert [{t1, true, _}, {t2, false, _}] = simulate(true, nil, 1500)
      assert t1 in 60..63 and t2 in 600..603
    end

    test "Ethernet run with a phone: off at ~600 s + 10 min linger" do
      assert [{_, true, _}, {t2, false, _}] = simulate(true, 300, 1500)
      assert t2 in 1200..1206
    end

    test "no network run: on at ~60 s and stays on" do
      assert [{_, true, _}] = simulate(false, nil, 3000)
    end
  end

  # ------------------------------------------------------- the password file ---
  describe "passwords and names" do
    test "generated passwords: 10 characters from the alphabet, no 0/O/o/1/l/I" do
      for _ <- 1..200 do
        p = Hotspot.gen_password()
        assert byte_size(p) == 10 and Hotspot.valid_password?(p)
        refute String.contains?(p, ~w(0 O o 1 l I))
      end

      assert byte_size(Hotspot.gen_password(63)) == 63
    end

    test "every character of the alphabet turns up (the choice is not biased onto a few)" do
      seen = for _ <- 1..400, c <- String.graphemes(Hotspot.gen_password()), into: MapSet.new(), do: c
      assert MapSet.size(seen) == 55
    end

    test "8 and 63 characters are valid; 7, 64, non-ASCII, tabs, and non-strings are not" do
      assert Hotspot.valid_password?(String.duplicate("x", 8)) and Hotspot.valid_password?(String.duplicate("x", 63))
      refute Hotspot.valid_password?(String.duplicate("x", 7))
      refute Hotspot.valid_password?(String.duplicate("x", 64))
      refute Hotspot.valid_password?("abcdefgé")
      refute Hotspot.valid_password?("abc\tdefgh")
      refute Hotspot.valid_password?(nil)
      assert Hotspot.valid_password(String.duplicate("x", 8))
    end

    test "SSID from the MAC" do
      assert Hotspot.ssid_for("dc:a6:32:12:ab:cd") == "Alnasl-setup-ABCD"
      assert Hotspot.ssid_for("") == "Alnasl-setup-0000"
      assert Hotspot.ssid_for(nil) == "Alnasl-setup-0000"
    end

    test "parse_file: the first PASSWORD= and HOTSPOT= count; uit/off/no/nee/0 switch it off" do
      assert Hotspot.parse_file("PASSWORD=x\r\nHOTSPOT=uit\r\n") == %{"password" => "x", "hotspot" => "off"}
      assert Hotspot.parse_file("PASSWORD=x\nHOTSPOT=auto\n")["hotspot"] == "auto"
      assert Hotspot.parse_file("PASSWORD=a\nPASSWORD=b\n")["password"] == "a"
      assert Hotspot.parse_file("# nothing\n") == %{"password" => nil, "hotspot" => "auto"}
      for v <- ~w(off Uit NO nee 0), do: assert(Hotspot.parse_file("HOTSPOT=#{v}")["hotspot"] == "off")
    end

    test "psk_hex is PBKDF2-HMAC-SHA1, 4096 rounds, 32 bytes" do
      # IEEE 802.11i test vector: passphrase "password", SSID "IEEE"
      assert Hotspot.psk_hex("IEEE", "password") == "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"
    end

    test "qr_stamp is a hash of ssid and password" do
      s = Hotspot.qr_stamp("Alnasl-setup-ABCD", "secretpw1")
      assert s =~ ~r/\A[0-9a-f]{64}\z/
      refute String.contains?(s, "secretpw1")

      assert s ==
               :crypto.hash(:sha256, "alnasl-hotspot-qr\0Alnasl-setup-ABCD\0secretpw1") |> Base.encode16(case: :lower)
    end

    test "render_file fills PASSWORD= and SSID=, replaces the old status line, ends CRLF" do
      text = "# header\r\nPASSWORD=\r\nSSID=old\r\nSSID=again\r\n# Box: old note\r\n"
      out = Hotspot.render_file(text, "pw12345678", "Alnasl-setup-ABCD", "new note")
      assert out == "# header\r\nPASSWORD=pw12345678\r\nSSID=Alnasl-setup-ABCD\r\n# Box: new note\r\n"
      # without a new note the old line stays
      assert Hotspot.render_file(text, "pw12345678", nil, nil) =~ "# Box: old note"
      # missing lines are added
      assert Hotspot.render_file("# h\n", "pw12345678", "S", nil) == "# h\r\nPASSWORD=pw12345678\r\nSSID=S\r\n"
    end
  end

  describe "prepare/6 (the file on the boot partition and the QR code)" do
    setup do
      Box.root!()
      Box.runner!(fn _ -> nil end)
      Box.put(@tpl, File.read!(@template))
      Box.put(@boot_file, File.read!(@template))
      :ok
    end

    defp prep(ssid \\ "Alnasl-setup-ABCD", note \\ nil) do
      with_io(fn -> Hotspot.prepare(ssid, @boot_file, @qr_file, @tpl, @stamp, note) end)
    end

    defp boot_text, do: File.read!(Sys.path(@boot_file))
    defp qr_matrix, do: QRDecoder.png_matrix(File.read!(Sys.path(@qr_file)), 10, 4)

    defp set_pw(value) do
      t =
        boot_text()
        |> String.split("\r\n")
        |> Enum.map(&if(String.starts_with?(&1, "PASSWORD="), do: "PASSWORD=" <> value, else: &1))

      File.write!(Sys.path(@boot_file), Enum.join(t, "\r\n"))
    end

    test "the template has its English and Dutch header, the QR and the serial-number note" do
      tpl = File.read!(@template)
      for w <- ["PASSWORD=", "wachtwoord", "QR", "serienummer", "serial number"], do: assert(String.contains?(tpl, w))
      refute String.contains?(tpl, "WACHTWOORD")
      assert tpl |> String.split(~r/\r?\n/) |> Enum.filter(&String.starts_with?(&1, "PASSWORD=")) == ["PASSWORD="]
    end

    test "an empty PASSWORD= gets a generated one, written back, with the SSID, the header and a note" do
      {{pw, st}, out} = prep()
      text = boot_text()
      assert Hotspot.valid_password?(pw)
      assert String.contains?(text, "PASSWORD=#{pw}\r\n")
      assert String.contains?(text, "SSID=Alnasl-setup-ABCD\r\n")
      refute String.contains?(String.replace(text, "\r\n", ""), "\n")
      assert String.starts_with?(text, "# ALNASL SETUP HOTSPOT")
      assert String.contains?(text, "# Box: a password was generated")
      refute String.contains?(out, pw)
      assert st["hotspot"] == "auto"
    end

    test "the QR code is written, is a plain PNG, and decodes to the join payload" do
      {{pw, _}, _} = prep()
      blob = File.read!(Sys.path(@qr_file))
      assert binary_part(blob, 0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>
      assert {:ok, {got, _, _}} = QRDecoder.decode(qr_matrix())
      assert got == "WIFI:T:WPA;S:Alnasl-setup-ABCD;P:#{pw};;"
    end

    test "a second boot changes nothing and does not rewrite the QR code; the stamp is a hash" do
      {{pw, _}, _} = prep()
      text = boot_text()
      qr1 = File.read!(Sys.path(@qr_file))
      File.touch!(Sys.path(@qr_file), {{2020, 1, 1}, {0, 0, 0}})
      mt = File.stat!(Sys.path(@qr_file)).mtime
      {{pw2, _}, _} = prep()
      assert pw2 == pw and boot_text() == text
      assert File.read!(Sys.path(@qr_file)) == qr1 and File.stat!(Sys.path(@qr_file)).mtime == mt
      stamp = File.read!(Sys.path(@stamp))
      assert String.trim(stamp) == Hotspot.qr_stamp("Alnasl-setup-ABCD", pw)
      refute String.contains?(stamp, pw)
    end

    test "another SSID (the card in another box): new QR, new SSID line" do
      prep()
      qr1 = File.read!(Sys.path(@qr_file))
      prep("Alnasl-setup-EF01")
      assert File.read!(Sys.path(@qr_file)) != qr1
      assert String.contains?(boot_text(), "SSID=Alnasl-setup-EF01")
    end

    test "an own password is kept as written, and its QR code escapes ; , and \"" do
      prep()
      set_pw("Our hall; 2026, \"main\"")
      {{pw3, _}, out} = prep()
      assert pw3 == "Our hall; 2026, \"main\""
      assert {:ok, {got, _, _}} = QRDecoder.decode(qr_matrix())
      assert got == ~s(WIFI:T:WPA;S:Alnasl-setup-ABCD;P:Our hall\\; 2026\\, \\"main\\";;)
      refute String.contains?(out, pw3)
    end

    test "a 5-character password is replaced, and the file says why; neither is logged" do
      prep()
      set_pw("short")
      {{pw4, _}, out} = prep()
      assert pw4 != "short" and Hotspot.valid_password?(pw4)
      assert String.contains?(boot_text(), "was not 8 to 63")
      refute String.contains?(out, "short")
      refute String.contains?(out, pw4)
    end

    test "a trailing space from an editor is dropped" do
      prep()
      set_pw("trailing space ok ")
      {{pw5, _}, _} = prep()
      assert pw5 == "trailing space ok"
    end

    test "a note stays across boots, one line of it" do
      prep()
      set_pw("trailing space ok")
      prep("Alnasl-setup-ABCD", ~s(joined Wi-Fi "Hall"))
      {{pw6, _}, _} = prep()
      assert pw6 == "trailing space ok"
      lines = boot_text() |> String.split("\r\n") |> Enum.filter(&String.starts_with?(&1, "# Box:"))
      assert lines == [~s(# Box: joined Wi-Fi "Hall")]
    end

    test "a deleted file is made again from the template" do
      prep()
      File.rm!(Sys.path(@boot_file))
      {{pw7, _}, out} = prep()
      assert File.exists?(Sys.path(@boot_file)) and Hotspot.valid_password?(pw7)
      assert String.contains?(boot_text(), "# ALNASL SETUP HOTSPOT")
      assert String.contains?(out, "was missing; made again from the image's copy")
    end

    test "no SSID (no wlan0 yet): the file is made, no QR code" do
      {{pw, _}, _} = prep(nil)
      assert String.contains?(boot_text(), "PASSWORD=#{pw}") and String.contains?(boot_text(), "SSID=\r\n")
      refute File.exists?(Sys.path(@qr_file))
    end

    test "FAT writes: written, renamed, then `sync` is run" do
      prep()
      assert ["sync"] in Box.ran()
      refute File.exists?(Sys.path(@boot_file) <> ".new")
    end
  end

  # ------------------------------------------------------------------ hostapd ---
  describe "hostapd_conf/3" do
    test "WPA2-PSK with CCMP, the derived key, and no passphrase" do
      pw = "Kp7xR3mQ2w"
      conf = Hotspot.hostapd_conf("Alnasl-setup-ABCD", pw, "BE")
      lines = Map.new(String.split(conf, "\n", trim: true), &List.to_tuple(String.split(&1, "=", parts: 2)))
      assert lines["wpa"] == "2" and lines["wpa_key_mgmt"] == "WPA-PSK" and lines["rsn_pairwise"] == "CCMP"
      assert lines["wpa_psk"] == Hotspot.psk_hex("Alnasl-setup-ABCD", pw)
      refute conf =~ "wpa_passphrase"
      refute String.contains?(conf, pw)
      assert lines["interface"] == "wlan0" and lines["country_code"] == "BE"
      assert lines["ssid"] == "Alnasl-setup-ABCD" and lines["ctrl_interface"] == "/run/alnasl-hotspot/hostapd"
      assert String.ends_with?(conf, "\n")
    end

    test "a country with a line in it becomes BE and smuggles nothing in" do
      sneaky = Hotspot.hostapd_conf("Alnasl-setup-ABCD", "Kp7xR3mQ2w", "NL\nwpa=0")
      assert String.contains?(sneaky, "country_code=BE\n")
      refute String.contains?(sneaky, "wpa=0")
      assert String.contains?(Hotspot.hostapd_conf("S", "Kp7xR3mQ2w", "NL"), "country_code=NL\n")
      assert String.contains?(Hotspot.hostapd_conf("S", "Kp7xR3mQ2w", nil), "country_code=BE\n")
    end

    test "no valid password, no hotspot (rather than an open one)" do
      for bad <- ["", nil, "short", String.duplicate("x", 64)] do
        assert_raise ArgumentError, ~r/no valid password/, fn -> Hotspot.hostapd_conf("S", bad, "BE") end
      end
    end

    test "the network file gives wlan0 10.42.0.1/24 and nothing else" do
      t = Hotspot.network_file()
      assert t =~ "[Match]\nName=wlan0\n"
      assert t =~ "Address=10.42.0.1/24\nDHCP=no\nLinkLocalAddressing=no\n"
      assert t =~ "ConfigureWithoutCarrier=yes"
    end
  end

  # ------------------------------------------------------- the daemon, on a fake box ---
  describe "the daemon" do
    @mac "dc:a6:32:12:ab:cd\n"

    setup do
      Box.root!()
      HotspotServer.install(%{nets: [], country: "BE", scan: %{"networks" => [%{"ssid" => "Hall"}]}})
      Box.put(@tpl, File.read!(@template))
      Box.put("/sys/class/net/wlan0/address", @mac)
      Box.put("/proc/uptime", "100.00 400.00\n")
      {:ok, net} = Agent.start_link(fn -> %{eth: [], wlan: [], wpa: ""} end)
      ap_json = fn addrs -> Json.encode([%{"addr_info" => Enum.map(addrs, &%{"local" => &1, "scope" => "global"})}]) end

      Box.runner!(fn
        ["ip", "-j", "-4", "addr", "show", "dev", "eth0"] ->
          {0, ap_json.(Agent.get(net, & &1.eth))}

        ["ip", "-j", "-4", "addr", "show", "dev", "wlan0"] ->
          {0, ap_json.(Agent.get(net, & &1.wlan))}

        ["wpa_cli" | _] ->
          {0, Agent.get(net, & &1.wpa)}

        ["systemctl", "is-active", _] ->
          {0, "active\n"}

        ["iw", "dev", "wlan0", "station", "dump"] ->
          {0, "Station aa:bb:cc:dd:ee:ff (on wlan0)\n\tinactive time: 10 ms\n"}

        _ ->
          nil
      end)

      %{net: net}
    end

    defp run_dir(f), do: Sys.path("/run/alnasl-hotspot/" <> f)
    defp status, do: run_dir("status.json") |> File.read!() |> Json.decode() |> elem(1)

    defp start do
      {state, _} = with_io(fn -> Hotspot.startup(Hotspot.new_state()) end)
      state
    end

    test "new_state takes the boot time from /proc/uptime" do
      s = Hotspot.new_state()
      assert_in_delta Sys.now() - s.boot, 100.0, 2.0
      assert s.no_net_since == s.boot and s.ap_on == false and s.reason == "starting"
    end

    test "startup: the identity (SSID from the MAC, password in the boot file, QR code)" do
      s = start()
      assert s.ssid == "Alnasl-setup-ABCD" and Hotspot.valid_password?(s.password) and s.enabled
      assert File.exists?(Sys.path(@boot_file)) and File.exists?(Sys.path(@qr_file))
    end

    test "HOTSPOT=off in the file switches it off" do
      Box.put(@boot_file, "PASSWORD=Kp7xR3mQ2w\r\nHOTSPOT=off\r\n")
      s = start()
      refute s.enabled
      {_s, _} = with_io(fn -> Hotspot.iterate(s) end)
      assert %{"reason" => "disabled", "active" => false, "enabled" => false} = status()
    end

    test "on Ethernet after the window: nothing to do, the status says so", %{net: net} do
      Box.put("/proc/uptime", "1000.00 400.00\n")
      Box.put("/sys/class/net/eth0/carrier", "1\n")
      Agent.update(net, &%{&1 | eth: ["192.168.1.5"]})
      s = start()
      {s, delay} = with_io(fn -> Hotspot.iterate(s) end) |> elem(0)
      assert delay == 3000 and s.had_network and not s.ap_on

      assert %{"active" => false, "reason" => "ethernet", "ssid" => "Alnasl-setup-ABCD", "address" => "10.42.0.1"} =
               status()

      assert is_float(status()["updated"])
    end

    test "no network, 100 s after boot: the access point comes up", %{net: net} do
      Agent.update(net, &%{&1 | wlan: ["10.42.0.1"]})
      s = start()
      {{s, delay}, out} = with_io(fn -> Hotspot.iterate(s) end)
      assert s.ap_on and delay == 3000
      assert out =~ "hotspot Alnasl-setup-ABCD is on (no_network); the setup page is http://10.42.0.1/"

      assert File.read!(run_dir("active")) == "wlan0 10.42.0.1\n"
      conf = File.read!(run_dir("hostapd.conf"))
      assert conf =~ "wpa_psk=" and conf =~ "ssid=Alnasl-setup-ABCD\n"
      refute String.contains?(conf, s.password)
      assert File.read!(Sys.path("/run/systemd/network/05-alnasl-hotspot.network")) == Hotspot.network_file()

      assert %{"networks" => [%{"ssid" => "Hall"}], "t" => t} =
               run_dir("scan.json") |> File.read!() |> Json.decode() |> elem(1)

      assert is_float(t)
      assert %{"active" => true, "reason" => "no_network"} = status()

      ran = Box.ran()
      assert ["systemctl", "stop", "wpa_supplicant@wlan0.service"] in ran
      assert ["systemctl", "restart", "alnasl-hotspot-ap.service"] in ran
      assert ["systemctl", "restart", "alnasl-hotspot-dns.service"] in ran
      assert ["systemctl", "restart", "alnasl-portal.service"] in ran
      assert ["/usr/local/sbin/alnasl-firewall", "reload"] in ran
      assert ["sysctl", "-q", "-w", "net.ipv4.conf.wlan0.forwarding=0"] in ran
      refute Enum.any?(ran, fn argv -> Enum.any?(argv, &String.contains?(&1, s.password)) end)
    end

    @tag :unix
    test "hostapd.conf is 0600" do
      s = start()
      with_io(fn -> Hotspot.iterate(s) end)
      assert Bitwise.band(File.stat!(run_dir("hostapd.conf")).mode, 0o777) == 0o600
    end

    test "an access point that does not come up leaves wlan0 a Wi-Fi client", %{net: _net} do
      Box.runner!(fn
        ["systemctl", "is-active", _] -> {3, "inactive\n"}
        ["ip", "-j" | _] -> {0, "[]"}
        _ -> nil
      end)

      s = start()
      {{s, _}, out} = with_io(fn -> Hotspot.iterate(s) end)
      refute s.ap_on
      assert s.fail_until > Sys.now() + 100
      assert out =~ "the access point did not come up"
      refute File.exists?(run_dir("active"))
    end

    test "--stop puts wlan0 back in client mode and says so in the status", %{net: net} do
      Agent.update(net, &%{&1 | wlan: ["10.42.0.1"]})
      s = start()
      with_io(fn -> Hotspot.iterate(s) end)
      assert File.exists?(run_dir("active"))
      {code, _} = with_io(fn -> Hotspot.main(["--stop"]) end)
      assert code == 0
      refute File.exists?(run_dir("active"))
      refute File.exists?(Sys.path("/run/systemd/network/05-alnasl-hotspot.network"))
      assert_received {:write_wpa, "BE", []}
      assert %{"active" => false, "reason" => "stopped", "enabled" => false, "portal" => nil, "ssid" => nil} = status()
    end

    test "--prepare only writes the file and the QR code" do
      {code, _} = with_io(fn -> Hotspot.main(["--prepare"]) end)
      assert code == 0
      assert File.exists?(Sys.path(@boot_file)) and File.exists?(Sys.path(@qr_file))
      refute File.exists?(run_dir("status.json"))
    end

    test "a left-over hotspot of an earlier run is put back to client mode first" do
      Box.put("/run/alnasl-hotspot/active", "wlan0 10.42.0.1\n")
      {_s, out} = with_io(fn -> Hotspot.startup(Hotspot.new_state()) end)
      assert out =~ "a hotspot of an earlier run was still up; put back to client mode first"
      refute File.exists?(run_dir("active"))
    end

    test "with a network and a pending Arkab join link: handed over, noted in the file", %{net: net} do
      HotspotServer.install(%{arkab_result: "joined", nets: [%{"ssid" => "00"}]})
      Box.put("/sys/class/net/eth0/carrier", "1\n")
      Box.put("/proc/uptime", "1000.00 1.0\n")
      Box.put("/run/alnasl-setup/arkab-pending.json", "{}")
      Agent.update(net, &%{&1 | eth: ["192.168.1.5"]})
      s = start()
      with_io(fn -> Hotspot.iterate(s) end)
      assert_received {:arkab_join_pending}
      assert boot_text() =~ "# Box: Arkab's join link from the setup page: joined"
    end

    test "eth_up?/0 needs carrier and an address; client_up?/0 needs COMPLETED and a non-hotspot address", %{net: net} do
      Box.put("/sys/class/net/eth0/carrier", "1\n")
      Box.put("/sys/class/net/lo/carrier", "1\n")
      refute Hotspot.eth_up?()
      Agent.update(net, &%{&1 | eth: ["192.168.1.5"]})
      assert Hotspot.eth_up?()

      Agent.update(net, &%{&1 | wpa: "wpa_state=COMPLETED\n", wlan: ["10.42.0.1"]})
      refute Hotspot.client_up?()
      Agent.update(net, &%{&1 | wlan: ["10.42.0.1", "192.168.1.77"]})
      assert Hotspot.client_up?()
      Agent.update(net, &%{&1 | wpa: "wpa_state=SCANNING\n"})
      refute Hotspot.client_up?()
    end

    test "stations/0 counts the Station lines" do
      assert Hotspot.stations() == 1
    end

    # --- the page asked for a network ---
    defp put_join(map), do: Box.put("/run/alnasl-hotspot/join.json", Json.encode(map))

    test "a join that works: the file is consumed, the passphrase goes only to the connect call, the file notes it" do
      put_join(%{"ssid" => "Hall", "passphrase" => "hunter22hunter", "hidden" => false, "country" => "NL"})
      s = start()
      {{s, delay}, out} = with_io(fn -> Hotspot.iterate(s) end)
      assert delay == 0
      refute File.exists?(run_dir("join.json"))
      assert_received {:connect, "Hall", "hunter22hunter", false, "NL"}
      assert %{"ok" => true, "ssid" => "Hall", "ip" => "192.168.1.9"} = s.last_join
      assert is_binary(s.last_join["host"]) and is_float(s.last_join["at"])
      assert s.had_network
      assert out =~ ~s(a network was chosen on the setup page: "Hall"; the hotspot steps aside to try it)
      assert out =~ ~s|joined "Hall" (192.168.1.9); the hotspot stays off|
      refute String.contains?(out, "hunter22hunter")

      assert boot_text() =~
               ~r/# Box: joined Wi-Fi "Hall" on \d{4}-\d\d-\d\d \d\d:\d\d: address 192\.168\.1\.9, name .+.local/

      assert %{"last_join" => %{"ok" => true}, "reason" => "joining"} = status()
    end

    test "a join that fails: the hotspot is held on for 10 minutes" do
      HotspotServer.install(%{connect: %{"ok" => false, "reason" => "wrong_password"}})
      put_join(%{"ssid" => "Hall", "passphrase" => "nope", "hidden" => true})
      s = start()
      {{s, 0}, out} = with_io(fn -> Hotspot.iterate(s) end)
      assert_received {:connect, "Hall", "nope", true, "BE"}
      assert %{"ok" => false, "reason" => "wrong_password", "ssid" => "Hall"} = s.last_join
      assert_in_delta s.hold_until, Sys.now() + 600, 5
      assert out =~ ~s|joining "Hall" did not work (wrong_password); the hotspot comes back|
    end

    test "joined but no address yet: waits up to 15 s for one, then no_address" do
      HotspotServer.install(%{connect: %{"ok" => true}, wlan_ip: nil})
      put_join(%{"ssid" => "Hall"})
      s = start()
      {{s, _}, _} = with_io(fn -> Hotspot.iterate(s) end)
      assert %{"ok" => false, "reason" => "no_address"} = s.last_join

      HotspotServer.install(%{connect: %{"ok" => true}, wlan_ip: "192.168.5.5"})
      put_join(%{"ssid" => "Hall"})
      {{s, _}, _} = with_io(fn -> Hotspot.iterate(s) end)
      assert %{"ok" => true, "ip" => "192.168.5.5"} = s.last_join
    end

    test "a bad request from the connect call is bad_request" do
      HotspotServer.install(%{connect: fn _, _, _, _ -> raise ArgumentError, "bad ssid" end})
      put_join(%{"ssid" => "Hall"})
      s = start()
      {{s, _}, _} = with_io(fn -> Hotspot.iterate(s) end)
      assert %{"ok" => false, "reason" => "bad_request"} = s.last_join
    end

    test "take_join: not JSON, not an object, or no ssid: removed and ignored" do
      for junk <- ["not json", "[1]", ~s({"passphrase": "x"}), ~s({"ssid": ""})] do
        Box.put("/run/alnasl-hotspot/join.json", junk)
        assert Hotspot.take_join() == nil
        refute File.exists?(run_dir("join.json"))
      end

      assert Hotspot.take_join() == nil
    end

    @tag :unix
    test "take_join does not follow a symlink" do
      target = Box.put("/run/alnasl-hotspot/elsewhere", ~s({"ssid": "Evil"}))
      File.ln_s!(target, run_dir("join.json"))
      assert Hotspot.take_join() == nil
      assert File.exists?(target)
    end
  end

  describe "starts_at: when the screen may promise the hotspot" do
    test "waiting after a lost network: five minutes from the loss; never had one: the boot grace" do
      s = %{Hotspot.new_state() | boot: 100.0, no_net_since: 1000.0, reason: "waiting", had_network: true}
      assert Hotspot.starts_at(s) == 1300.0
      assert Hotspot.starts_at(%{s | had_network: false}) == 1060.0
      assert Hotspot.starts_at(%{s | reason: "boot_grace"}) == 160.0
    end

    test "on, on a network, or no Wi-Fi: no promise" do
      for r <- ["no_network", "ethernet", "wifi_client", "no_wlan", "hold", "disabled"],
          do: assert(Hotspot.starts_at(%{Hotspot.new_state() | reason: r}) == nil)
    end
  end
end
