defmodule AlnaslSetup.CompactTest do
  # The compact screen (AlnaslSetup.Compact, v7.4): which picture a small screen shows with nobody touching it,
  # the two-minute QR window after every start, and what the QR code says. Plus the UI= switch that turns it on.
  use ExUnit.Case, async: false
  alias AlnaslSetup.Compact, as: C
  alias AlnaslSetup.SmallScreen, as: S

  @hs %{"active" => true, "ssid" => "Alnasl-setup-1a2b", "password" => "abcdefghjk"}
  @eth %{"iface" => "eth0", "ip" => "192.168.0.50"}
  @wlan %{"iface" => "wlan0", "ip" => "192.168.1.9"}

  defp i(over),
    do:
      Map.merge(
        %{done: true, since: 1000.0, now: 1000.0, force_qr: false, hotspot: %{}, addrs: [@eth], port: 4040},
        over
      )

  describe "the tailnet address on the home screen" do
    test "only a connected box with an address shows one" do
      alias AlnaslSetup.Server.Remote, as: R

      assert R.address_of(%{"state" => "connected", "ip" => "100.64.1.2", "dns_name" => "alnasl-1.tail.ts.net"}) ==
               %{"ip" => "100.64.1.2", "dns_name" => "alnasl-1.tail.ts.net"}

      for s <- [
            %{"state" => "off"},
            %{"state" => "login", "url" => "https://x"},
            %{"state" => "connected", "ip" => nil}
          ],
          do: assert(R.address_of(s) == nil)
    end

    test "remote access off: no address, and Tailscale is not asked" do
      assert AlnaslSetup.Server.Remote.address() == nil
    end
  end

  describe "which picture" do
    test "a box that is not set up shows the QR code, however long it has been up" do
      for now <- [1000.0, 1119.0, 1121.0, 100_000.0], do: assert(C.decide(i(%{done: false, now: now}))["view"] == "qr")
    end

    test "a set-up box: the QR code for the first two minutes after the start, then the status" do
      assert C.qr_seconds() == 120
      assert %{"view" => "qr", "qr_left" => 120} = C.decide(i(%{now: 1000.0}))
      assert %{"view" => "qr", "qr_left" => 1} = C.decide(i(%{now: 1119.5}))
      assert %{"view" => "stats", "qr_left" => 0} = C.decide(i(%{now: 1120.0}))
      assert C.decide(i(%{now: 5000.0}))["view"] == "stats"
    end

    test "the menu's 'Show the QR code' wins over the clock" do
      assert %{"view" => "qr", "qr_left" => 0} = C.decide(i(%{now: 5000.0, force_qr: true}))
    end
  end

  describe "what the QR code says" do
    test "the setup hotspot first: joining it opens the setup page" do
      q = C.qr_target(i(%{hotspot: @hs}))
      assert q["kind"] == "hotspot" and q["text"] == "WIFI:T:WPA;S:Alnasl-setup-1a2b;P:abcdefghjk;;"
    end

    test "no hotspot: the role's page on the hall network, Ethernet's address before Wi-Fi's" do
      assert C.qr_target(i(%{addrs: [@wlan, @eth]}))["url"] == "http://192.168.0.50:4040/"
      assert C.qr_target(i(%{addrs: [@wlan], port: 4050}))["url"] == "http://192.168.1.9:4050/"
    end

    test "a hotspot without its password, no address, or a role with no page: no code" do
      assert C.qr_target(i(%{hotspot: Map.delete(@hs, "password"), addrs: []}))["kind"] == "none"
      assert C.qr_target(i(%{hotspot: Map.put(@hs, "active", false), addrs: []}))["kind"] == "none"
      assert C.qr_target(i(%{port: nil}))["kind"] == "none"
    end

    test "no code yet but a hotspot on its way: how many seconds until it comes on by itself" do
      wait = Map.merge(@hs, %{"active" => false, "starts_at" => 1250.4})
      assert %{"kind" => "none", "starts_in" => 250} = C.qr_target(i(%{hotspot: wait, addrs: []}))
      assert C.qr_target(i(%{hotspot: Map.put(wait, "starts_at", 900.0), addrs: []}))["starts_in"] == 0
      assert C.qr_target(i(%{hotspot: Map.delete(wait, "starts_at"), addrs: []}))["starts_in"] == nil
    end

    test "the code is drawn from rows of 0 and 1, square" do
      r = C.rows("http://192.168.0.50:4040/")
      assert length(r) >= 21 and Enum.all?(r, &(String.length(&1) == length(r) and &1 =~ ~r/\A[01]+\z/))
    end
  end

  describe "when it is on (UI= in alnasl-screen.txt)" do
    test "auto: compact on a panel on the pins, normal on HDMI (the 3.5-inch HDMI stylus screen too)" do
      for s <- ~w(waveshare35a piscreen waveshare32b hx8357d),
          do: assert(S.ui_mode(S.parse("SCREEN=#{s}\n")) == "compact")

      assert S.ui_mode(S.parse("SCREEN=hdmi\n")) == "normal"
      assert S.ui_mode(S.parse("TOUCH=xpt2046\n")) == "normal"
      assert S.ui_mode(S.parse(nil)) == "normal"
    end

    test "UI=compact and UI=normal decide; anything else is auto, and said so" do
      assert S.ui_mode(S.parse("SCREEN=hdmi\nUI=compact\n")) == "compact"
      assert S.ui_mode(S.parse("SCREEN=waveshare35a\nUI=normal\n")) == "normal"
      p = S.parse("SCREEN=hdmi\nUI=tiny\n")
      assert p.ui == "auto" and S.ui_mode(p) == "normal" and Enum.any?(p.problems, &(&1 =~ "UI=tiny"))
    end
  end
end
