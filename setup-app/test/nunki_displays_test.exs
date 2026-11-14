defmodule AlnaslSetup.NunkiDisplaysTest do
  # v7.5 (docs/nunki-displays.md, docs/remote-access.md): a nunki box's screen layouts (the same table as kiosk.sh's
  # nunki_plan, which scripts/test-kiosk-logic.sh checks from the other end), the touch panel's Nunki controls
  # against a fake Nunki local API, and what the remote-access page shows for each Tailscale state.
  use ExUnit.Case, async: false
  alias AlnaslSetup.{Http, Json, Sys}
  alias AlnaslSetup.Server.{Displays, Nunki, Remote, State}
  alias AlnaslSetup.Test.Box

  @h1 "card0-HDMI-A-1"
  @h2 "card0-HDMI-A-2"

  describe "the layout file" do
    test "no file, or nonsense in it, is auto with nothing swapped" do
      assert Displays.parse("") == Displays.defaults()
      assert Displays.parse("LAYOUT=sideways\nSWAP=yes\nROTATE1=upside\n") == Displays.defaults()
    end

    test "round trip, CRLF and quotes forgiven" do
      c = %{"layout" => "two", "swap" => true, "rotate1" => "left", "rotate2" => "inverted"}
      assert Displays.parse(Displays.serialize(c)) == c
      assert Displays.parse("LAYOUT=\"mirror\"\r\nSWAP=1\r\n")["layout"] == "mirror"
    end

    test "serialize refuses what the kiosk would not take" do
      assert_raise ArgumentError, fn -> Displays.serialize(%{"layout" => "three"}) end
      assert_raise ArgumentError, fn -> Displays.serialize(%{"rotate2" => "diagonal"}) end
      assert_raise ArgumentError, fn -> Displays.serialize(%{"swap" => "1"}) end
    end
  end

  describe "the plan (kiosk.sh's nunki_plan)" do
    defp jobs(conn, cfg),
      do: for(o <- Displays.plan(conn, Map.merge(Displays.defaults(), cfg))["outputs"], do: {o["label"], o["job"]})

    test "defaults: one monitor is the broadcast; two are management on HDMI 0 and the broadcast on HDMI 1" do
      assert jobs([@h1], %{}) == [{"HDMI 0", "hall1"}]
      assert jobs([@h1, @h2], %{}) == [{"HDMI 0", "manage"}, {"HDMI 1", "hall1"}]
    end

    test "every layout with two monitors, and swap" do
      assert jobs([@h1, @h2], %{"layout" => "single"}) == [{"HDMI 0", "hall1"}, {"HDMI 1", nil}]
      assert jobs([@h1, @h2], %{"layout" => "mirror"}) == [{"HDMI 0", "hall1"}, {"HDMI 1", "hall1"}]
      assert jobs([@h1, @h2], %{"layout" => "two"}) == [{"HDMI 0", "hall1"}, {"HDMI 1", "hall2"}]
      assert jobs([@h1, @h2], %{"layout" => "manage", "swap" => true}) == [{"HDMI 1", "manage"}, {"HDMI 0", "hall1"}]
    end

    test "a two-monitor layout with one connected falls back to one broadcast, and says so" do
      p = Displays.plan([@h2], Map.put(Displays.defaults(), "layout", "two"))
      assert p["layout"] == "single" and p["fallback"]
      assert [%{"label" => "HDMI 1", "job" => "hall1"}] = p["outputs"]
      assert Displays.plan([], Displays.defaults())["layout"] == nil
    end

    test "the kiosk's window list" do
      w = Displays.windows("1 HDMI-1 manage 1920x1080+0+0\n2 HDMI-2 hall1 1280x720+1920+0\nrubbish\n")
      assert [%{"n" => 1, "job" => "manage", "w" => 1920}, %{"n" => 2, "x" => 1920, "h" => 720}] = w
    end
  end

  describe "the box's monitors and identify" do
    setup do
      Box.root!()
      start_supervised!(State)
      :ok
    end

    test "connected HDMI connectors from sysfs, in order" do
      Box.put("/sys/class/drm/card0-HDMI-A-2/status", "connected\n")
      Box.put("/sys/class/drm/card0-HDMI-A-1/status", "disconnected\n")
      Box.put("/sys/class/drm/card1-SPI-1/status", "connected\n")
      assert Displays.connected() == [@h2]
      Box.put("/sys/class/drm/card0-HDMI-A-1/status", "connected\n")
      assert Displays.connected() == [@h1, @h2]
    end

    test "identify: on for eight seconds, with each window's place and what it is" do
      Box.put("/run/alnasl-kiosk/outputs", "1 HDMI-1 manage 1920x1080+0+0\n2 HDMI-2 hall1 1920x1080+1920+0\n")
      assert Displays.identify() == %{"active" => false}
      assert %{"seconds" => 8} = Displays.identify_start()
      assert %{"active" => true, "outputs" => [o1, o2]} = Displays.identify()
      assert o1["what"] == "HDMI 0: Management" and o2["what"] == "HDMI 1: Hall screen 1"
    end
  end

  describe "Nunki's local API, through the panel's proxy" do
    setup do
      start_supervised!(State)
      me = self()

      handler = fn req ->
        send(me, {:nunki, req.method, req.path, req.body})

        case Process.get(:mode) || :persistent_term.get({__MODULE__, :mode}, :new) do
          :old -> {404, [{"Content-Type", "text/html"}], "not found"}
          _ when req.method == "POST" and req.path == "/api/local/v1/screen" -> {422, [], ~s({"error":"bad"})}
          :new -> {200, [{"Content-Type", "application/json"}], Json.encode(state(:new))}
          :first -> {200, [{"Content-Type", "application/json"}], Json.encode(state(:first))}
        end
      end

      start_supervised!({Http, id: :fake_nunki, ip: {127, 0, 0, 1}, port: 0, handler: handler, server: "fake-nunki"})
      Application.put_env(:alnasl_setup, :nunki_url, "http://127.0.0.1:#{Http.port(:fake_nunki)}")

      on_exit(fn ->
        Application.delete_env(:alnasl_setup, :nunki_url)
        :persistent_term.erase({__MODULE__, :mode})
      end)

      :ok
    end

    defp state(:first),
      do: %{
        "screen" => "paused",
        "audio" => false,
        "hall_tournament" => 7,
        "tournaments" => [%{"id" => 7, "name" => "Open A", "connected" => true}],
        "countdown" => nil,
        "version" => "0.6.9"
      }

    defp state(:new),
      do:
        Map.put(state(:first), "screens", %{
          "hdmi1" => %{"mode" => "live", "tournament" => 7},
          "hdmi2" => %{"mode" => "black", "tournament" => nil}
        })

    test "a Nunki with two screens" do
      assert %{"ok" => true, "state" => s} = Nunki.state()
      assert s["two_screens"] and s["screens"]["hdmi2"]["mode"] == "black"
      assert [%{"name" => "Open A", "connected" => true}] = s["tournaments"]
    end

    test "the first API v1: one hall screen, from the top-level fields" do
      :persistent_term.put({__MODULE__, :mode}, :first)
      assert %{"ok" => true, "state" => s} = Nunki.state()
      assert s["screens"] == %{"hdmi1" => %{"mode" => "paused", "tournament" => 7}} and not s["two_screens"]
    end

    test "a Nunki older than the API says so; one that does not answer says that" do
      :persistent_term.put({__MODULE__, :mode}, :old)
      assert Nunki.state() == %{"ok" => false, "reason" => "old"}
      Application.put_env(:alnasl_setup, :nunki_url, "http://127.0.0.1:1")
      assert Nunki.state() == %{"ok" => false, "reason" => "down"}
    end

    test "the buttons: validated here, sent as the API wants, 422 is a refusal" do
      assert Nunki.set_audio(%{"enabled" => true}) == %{"ok" => true}
      assert_receive {:nunki, "POST", "/api/local/v1/audio", body}
      assert Json.decode_or_nil(body) == %{"enabled" => true}
      assert Nunki.set_tournament(%{"screen" => "hdmi2", "id" => 7}) == %{"ok" => true}
      assert_receive {:nunki, "POST", "/api/local/v1/hall_tournament", b2}
      assert Json.decode_or_nil(b2) == %{"screen" => "hdmi2", "id" => 7}
      assert Nunki.set_screen(%{"screen" => "hdmi1", "mode" => "black"}) == %{"ok" => false, "reason" => "refused"}
      assert_raise ArgumentError, fn -> Nunki.set_screen(%{"screen" => "hdmi3", "mode" => "live"}) end
      assert_raise ArgumentError, fn -> Nunki.set_screen(%{"mode" => "dimmed"}) end
      assert_raise ArgumentError, fn -> Nunki.set_audio(%{"enabled" => "yes"}) end
    end
  end

  describe "remote access: what the page shows" do
    @ctx %{on: true, now: 1000.0, started: 990.0, link_seen: 995.0}

    test "off is off, whatever tailscale might say" do
      assert Remote.summarize(%{"BackendState" => "Running"}, %{@ctx | on: false}) == %{"state" => "off"}
    end

    test "a login link: shown, and called stale after ten minutes" do
      st = %{"BackendState" => "NeedsLogin", "AuthURL" => "https://login.tailscale.com/a/abc123"}

      assert %{"state" => "login", "url" => "https://login.tailscale.com/a/abc123", "stale" => false} =
               Remote.summarize(st, @ctx)

      assert %{"stale" => true} = Remote.summarize(st, %{@ctx | now: 995.0 + Remote.link_stale()})
    end

    test "no link for thirty seconds after Start: most likely no internet" do
      assert %{"state" => "starting"} =
               Remote.summarize(%{"BackendState" => "NoState"}, %{@ctx | now: 1000.0, started: 990.0})

      assert %{"state" => "no_internet"} =
               Remote.summarize(%{"BackendState" => "NeedsLogin"}, %{@ctx | now: 1030.0, started: 990.0})

      assert %{"state" => "no_internet"} = Remote.summarize(%{}, %{@ctx | now: 1100.0, started: 990.0})
    end

    test "connected: the tailnet address and the MagicDNS name; logged out since a restart" do
      st = %{
        "BackendState" => "Running",
        "Self" => %{
          "TailscaleIPs" => ["fd7a:115c:a1e0::1", "100.101.102.103"],
          "DNSName" => "alnasl-1a2b.tail1234.ts.net."
        },
        "CurrentTailnet" => %{"Name" => "someone@example.com"}
      }

      assert %{
               "state" => "connected",
               "ip" => "100.101.102.103",
               "dns_name" => "alnasl-1a2b.tail1234.ts.net",
               "ssh" => true
             } =
               Remote.summarize(st, @ctx)

      assert %{"state" => "stopped"} = Remote.summarize(%{"BackendState" => "NeedsLogin"}, %{@ctx | started: nil})
      assert %{"state" => "approve"} = Remote.summarize(%{"BackendState" => "NeedsMachineAuth"}, @ctx)
    end
  end

  test "Sys.read is what the plan reads (the fake root seam works for the layout file)" do
    Box.root!()
    Box.put(Displays.conf_file(), "LAYOUT=two\nSWAP=1\n")
    assert %{"layout" => "two", "swap" => true} = Displays.parse(Sys.read(Displays.conf_file()))
  end
end
