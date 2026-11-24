defmodule AlnaslSetup.LiveBoardsTest do
  # v7.7 (docs/nunki-displays.md, "Live boards on HDMI"): the panel wizard's plan (which layout, which kiosk-res
  # layout call), the live apply with its confirm-or-revert, and what goes to Nunki's local API - against a fake
  # box (root + command runner) and a fake Nunki.
  use ExUnit.Case, async: false
  alias AlnaslSetup.{Http, Json}
  alias AlnaslSetup.Server.{Displays, LiveBoards, Nunki, State}
  alias AlnaslSetup.Test.Box

  @h1 "card0-HDMI-A-1"
  @h2 "card0-HDMI-A-2"

  defp monitors!(n) do
    Box.put("/sys/class/drm/#{@h1}/status", "connected\n")
    Box.put("/sys/class/drm/#{@h1}/modes", "1920x1080\n1920x1080\n1280x720\n1920x1080i\n")
    Box.put("/sys/class/drm/#{@h2}/status", if(n >= 2, do: "connected\n", else: "disconnected\n"))
    Box.put("/sys/class/drm/#{@h2}/modes", "1280x1024\n1024x768\n")
  end

  defp box!(state) do
    Box.root!()
    start_supervised!(State)
    Box.put("/run/alnasl-mode/role", "nunki\n")
    Box.put("/run/alnasl-kiosk/state", state)
    Application.put_env(:alnasl_setup, :later, :inline)
    on_exit(fn -> Application.delete_env(:alnasl_setup, :later) end)

    Box.runner!(fn
      ["systemctl", "is-enabled", _] -> {0, "enabled\n"}
      ["systemctl", "is-active", _] -> {0, "active\n"}
      ["docker", "exec" | _] -> {0, "x: done\n"}
      _ -> {0, ""}
    end)
  end

  defp kiosk_calls(log),
    do:
      for(
        ["docker", "exec" | rest] <- Box.ran(log),
        do: Enum.drop_while(rest, &(&1 != "/usr/local/bin/kiosk-res")) |> tl()
      )

  @live "path=x driver=modesetting layout=extend HDMI-1=hall1@1920x1080+0+0 HDMI-2=hall2@1280x1024+1920+0 scale=1.00 vt=vt1\n"

  describe "the plan" do
    test "what the wizard's second screen means" do
      assert LiveBoards.layout(1, "boards") == "single"
      assert LiveBoards.layout(2, "off") == "single"
      assert LiveBoards.layout(2, "mirror") == "mirror"
      assert LiveBoards.layout(2, "boards") == "two" and LiveBoards.layout(2, "hall") == "two"
    end

    test "a monitor's modes: progressive, preferred first, each once" do
      Box.root!()
      monitors!(2)
      assert Displays.modes(@h1) == ["1920x1080", "1280x720"]
    end

    test "kiosk-res layout arguments: own modes, an unlisted one is auto, mirror and single" do
      Box.root!()
      monitors!(2)
      cfg = Map.merge(Displays.defaults(), %{"layout" => "two", "mode1" => "1280x720", "mode2" => "1280x720"})

      assert Displays.layout_args([@h1, @h2], cfg) ==
               ~w(extend HDMI-1 hall1 1280x720 normal HDMI-2 hall2 auto normal)

      assert Displays.layout_args([@h1, @h2], %{cfg | "layout" => "mirror", "mode1" => "1024x768"}) ==
               ~w(mirror HDMI-1 hall1 auto normal HDMI-2 off auto normal)

      assert Displays.layout_args([@h1, @h2], %{cfg | "layout" => "single", "swap" => true}) ==
               ~w(single HDMI-2 hall1 auto normal HDMI-1 off 1280x720 normal)

      assert Displays.layout_args([@h1], cfg) == nil
    end

    test "board selections, as Nunki takes them" do
      assert Nunki.boards("") == {:ok, ""}
      assert Nunki.boards(" 1-4, 7 ") == {:ok, "1-4,7"}
      assert Nunki.boards("5-10") == {:ok, "5-10"}
      assert Nunki.boards("1-") == :error
      assert Nunki.boards("1;reboot") == :error
      assert Nunki.boards(Enum.map_join(1..21, ",", &to_string/1)) == :error
      assert Nunki.boards(4) == :error
    end
  end

  describe "applied live" do
    test "two monitors: one kiosk-res layout call, no restart; a new resolution waits for keep" do
      log = box!(@live)
      monitors!(2)

      assert %{"live" => true, "restart" => false, "pending" => true, "confirm_seconds" => 15} =
               Displays.apply_live(%{"layout" => "two", "mode1" => "1280x720"})

      assert kiosk_calls(log) == [~w(layout extend HDMI-1 hall1 1280x720 normal HDMI-2 hall2 auto normal)]
      assert Displays.get()["mode1"] == "1280x720"
      assert %{"pending" => true} = Displays.pending_status()
      refute Enum.any?(Box.ran(log), &match?(["systemctl", "restart" | _], &1))
      assert Displays.confirm() == %{"ok" => true}
      assert Displays.pending_status() == %{"pending" => false}
      assert Displays.get()["mode1"] == "1280x720"
    end

    test "undo, and a second change before keep goes back to the ORIGINAL" do
      log = box!(@live)
      monitors!(2)
      Displays.apply_live(%{"layout" => "two", "mode1" => "1280x720"})
      Displays.apply_live(%{"layout" => "mirror", "mode1" => "1920x1080"})
      Displays.undo()
      assert Displays.get()["mode1"] == "auto" and Displays.get()["layout"] == "auto"
      assert List.last(kiosk_calls(log)) == ~w(layout extend HDMI-1 manage auto normal HDMI-2 hall1 auto normal)
      assert Displays.pending_status() == %{"pending" => false}
    end

    test "not confirmed in time: the previous resolution comes back by itself" do
      Application.put_env(:alnasl_setup, :screens_confirm_seconds, -1.9)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :screens_confirm_seconds) end)
      box!(@live)
      monitors!(2)
      Displays.apply_live(%{"layout" => "two", "mode2" => "1024x768"})
      assert Displays.get()["mode2"] == "1024x768"
      assert wait_until(fn -> Displays.get()["mode2"] == "auto" end)
    end

    test "no resolution change: nothing to confirm" do
      box!(@live)
      monitors!(2)
      assert %{"live" => true, "pending" => false} = Displays.apply_live(%{"layout" => "mirror"})
    end

    test "a kiosk that does not lay itself out (fbdev, an older client) restarts instead" do
      log = box!("path=x driver=fbdev window-size=1920,1080\n")
      monitors!(2)
      assert %{"live" => false, "restart" => true} = Displays.apply_live(%{"layout" => "two"})
      assert ["systemctl", "restart", "--no-block", "alnasl-kiosk.service"] in Box.ran(log)
      assert kiosk_calls(log) == []
    end

    test "one monitor: kiosk-res apply with its mode" do
      log = box!("path=x driver=modesetting window-size=1920,1080\n")
      monitors!(1)
      assert %{"live" => true, "pending" => true} = Displays.apply_live(%{"mode1" => "1280x720"})
      assert kiosk_calls(log) == [~w(apply HDMI-A-1 1280x720 normal)]
    end

    test "only a nunki box" do
      box!(@live)
      Box.put("/run/alnasl-mode/role", "alnasl\n")
      assert_raise ArgumentError, "not_nunki", fn -> Displays.apply_live(%{"layout" => "two"}) end
    end
  end

  describe "the wizard's Done, through a fake Nunki" do
    setup do
      me = self()

      handler = fn req ->
        send(me, {:nunki, req.path, Json.decode_or_nil(req.body)})
        {200, [{"Content-Type", "application/json"}], ~s({"screens":{}})}
      end

      log = box!(@live)
      monitors!(2)
      start_supervised!({Http, id: :fake_nunki_lb, ip: {127, 0, 0, 1}, port: 0, handler: handler, server: "fake-nunki"})
      Application.put_env(:alnasl_setup, :nunki_url, "http://127.0.0.1:#{Http.port(:fake_nunki_lb)}")
      on_exit(fn -> Application.delete_env(:alnasl_setup, :nunki_url) end)
      {:ok, log: log}
    end

    test "boards 1-4 on the first, 5-10 on the second, each its resolution", %{log: log} do
      r =
        LiveBoards.apply(%{
          "tournament" => 7,
          "screens" => [%{"show" => "boards", "boards" => "1-4"}, %{"show" => "boards", "boards" => "5-10"}],
          "modes" => ["1280x720", "1024x768"]
        })

      assert %{"layout" => "two", "live" => true, "pending" => true, "nunki" => []} = r
      assert_receive {:nunki, "/api/local/v1/hall_tournament", %{"screen" => "hdmi1", "id" => 7}}

      assert_receive {:nunki, "/api/local/v1/screen_source",
                      %{"screen" => "hdmi1", "source" => "boards", "boards" => "1-4"}}

      assert_receive {:nunki, "/api/local/v1/hall_tournament", %{"screen" => "hdmi2", "id" => 7}}

      assert_receive {:nunki, "/api/local/v1/screen_source",
                      %{"screen" => "hdmi2", "source" => "boards", "boards" => "5-10"}}

      assert kiosk_calls(log) == [~w(layout extend HDMI-1 hall1 1280x720 normal HDMI-2 hall2 1024x768 normal)]
    end

    test "the same as HDMI 1: only hall screen 1 is set, the layout mirrors", %{log: log} do
      assert %{"layout" => "mirror"} =
               LiveBoards.apply(%{
                 "tournament" => nil,
                 "screens" => [%{"show" => "boards", "boards" => ""}, %{"show" => "mirror"}]
               })

      assert_receive {:nunki, "/api/local/v1/screen_source", %{"screen" => "hdmi1", "boards" => ""}}
      refute_receive {:nunki, _, %{"screen" => "hdmi2"}}, 100
      assert [["layout", "mirror" | _]] = kiosk_calls(log)
    end

    test "refused before anything is sent" do
      for bad <- [
            %{"screens" => [%{"show" => "mirror"}]},
            %{"screens" => [%{"show" => "boards", "boards" => "1-4;x"}]},
            %{"screens" => [%{"show" => "hall"}], "modes" => ["huge"]},
            %{"screens" => "two"}
          ] do
        assert_raise ArgumentError, fn -> LiveBoards.apply(bad) end
      end

      refute_receive {:nunki, _, _}, 100
    end
  end

  defp wait_until(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> receive(after: (50 -> wait_until(fun, tries - 1)))
    end
  end
end
