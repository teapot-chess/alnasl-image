defmodule AlnaslSetup.ResolutionTest do
  # Ported from scripts/test-res.py: the resolution logic of the settings server with a fake screen
  # (the DRM connector files), a fake live apply (docker exec ... kiosk-res answers from `live`) and a
  # fake systemctl. The confirm window is 1 s here (+2 s, as on the box), so the waits are real.
  use ExUnit.Case, async: false
  alias AlnaslSetup.Server.{Resolution, State}
  alias AlnaslSetup.{Sys, Test.Box}

  setup do
    Box.root!()
    Application.put_env(:alnasl_setup, :res_confirm_seconds, 1)
    Application.put_env(:alnasl_setup, :later, :inline)

    on_exit(fn ->
      Application.delete_env(:alnasl_setup, :res_confirm_seconds)
      Application.delete_env(:alnasl_setup, :later)
    end)

    {:ok, live} = Agent.start_link(fn -> %{ok: true, running: true} end)

    Box.runner!(fn
      ["docker", "exec" | _] -> if Agent.get(live, & &1.ok), do: {0, "stub"}, else: {1, "stub"}
      ["systemctl", "is-enabled", _] -> {0, "enabled\n"}
      ["systemctl", "is-active", _] -> if Agent.get(live, & &1.running), do: {0, "active\n"}, else: {3, "inactive\n"}
      _ -> nil
    end)

    Box.put("/sys/class/drm/card1-HDMI-A-1/status", "connected\n")
    Box.put("/sys/class/drm/card1-HDMI-A-1/modes", "1920x1080\n1280x720\n1920x1080i\n1280x720\n1024x768\n")
    Box.put("/sys/class/drm/card1-HDMI-A-2/status", "disconnected\n")
    Sys.write_atomic("/etc/alnasl/kiosk.conf", "KIOSK_SCALE=\"125\"\n")
    Sys.write_atomic("/run/alnasl-kiosk/state", "path=cage mode=1920x1080\n")
    start_supervised!(State)
    %{live: live}
  end

  defp conf, do: AlnaslSetup.Server.Box.get_kiosk_conf()

  defp applied do
    for ["docker", "exec" | rest] <- Box.ran(), do: rest |> Enum.take(-2) |> List.to_tuple()
  end

  defp restarts do
    Enum.count(Box.ran(), &(&1 == ["systemctl", "restart", "--no-block", "alnasl-kiosk.service"]))
  end

  defp set_live(live, kv), do: Agent.update(live, &Map.merge(&1, kv))

  test "the whole sequence of test-res.py", %{live: live} do
    r = Resolution.status()
    assert r["modes"] == ["1920x1080", "1280x720", "1024x768"]
    assert r["setting"] == "auto" and r["connector"] == "HDMI-A-1" and r["preferred"] == "1920x1080"
    assert r["pending"] == false and r["seconds_left"] == 0 and r["confirm_seconds"] == 1 and r["kiosk_running"] == true

    assert_raise ArgumentError, "The screen does not offer that resolution.", fn -> Resolution.set("800x600") end
    assert_raise ArgumentError, fn -> Resolution.set("1x1; reboot") end

    # apply + confirm
    j = Resolution.set("1280x720")
    assert j == %{"ok" => true, "live" => true, "restart" => false, "pending" => true, "confirm_seconds" => 1}
    assert conf()["KIOSK_RES"] == "1280x720" and conf()["KIOSK_SCALE"] == "125"
    assert Resolution.status()["pending"]
    assert Resolution.status()["seconds_left"] in [2, 3]
    assert Resolution.confirm() == %{"ok" => true}
    Process.sleep(3500)
    assert conf()["KIOSK_RES"] == "1280x720"
    refute {"HDMI-A-1", "auto"} in applied()

    # apply + no answer -> automatic revert to the previous mode, applied live
    Resolution.set("1024x768")
    Process.sleep(3800)
    assert conf()["KIOSK_RES"] == "1280x720"
    assert List.last(applied()) == {"HDMI-A-1", "1280x720"}
    refute Resolution.status()["pending"]

    # apply + Undo, and two changes in a row go back to the ORIGINAL
    Resolution.set("1024x768")
    Resolution.set("1920x1080")
    assert Resolution.cancel() == %{"ok" => true}
    assert conf()["KIOSK_RES"] == "1280x720"

    # the live apply fails (black screen risk): refused and nothing saved
    set_live(live, %{ok: false})
    assert_raise ArgumentError, "The screen would not switch: stub", fn -> Resolution.set("1024x768") end
    assert conf()["KIOSK_RES"] == "1280x720"
    set_live(live, %{ok: true})

    # revert whose live apply fails: restart the kiosk, which applies the saved value
    before = restarts()
    Resolution.set("auto")
    set_live(live, %{ok: false})
    Resolution.cancel()
    assert restarts() > before and conf()["KIOSK_RES"] == "1280x720"
    set_live(live, %{ok: true})

    # X on fbdev cannot switch live: saved + the screen restarts + a longer confirm window
    Sys.write_atomic("/run/alnasl-kiosk/state", "path=x driver=fbdev window-size=1920,1080\n")
    set_live(live, %{ok: false})
    Resolution.cancel()
    before = restarts()
    j = Resolution.set("1280x720")
    assert j["restart"] and j["pending"] and j["live"] == false
    assert restarts() > before and conf()["KIOSK_RES"] == "1280x720" and j["confirm_seconds"] > 20
    Resolution.cancel()
    assert conf()["KIOSK_RES"] in ["auto", "1280x720"]
    set_live(live, %{ok: true})
    Sys.write_atomic("/run/alnasl-kiosk/state", "path=cage mode=1920x1080\n")

    # kiosk not running: saved only, nothing pending
    set_live(live, %{running: false})
    j = Resolution.set("1024x768")
    assert j == %{"ok" => true, "live" => false, "pending" => false, "confirm_seconds" => 0}
    assert conf()["KIOSK_RES"] == "1024x768"
  end

  test "no screen: no modes, auto only", %{live: _} do
    File.rm_rf!(Sys.path("/sys/class/drm"))
    r = Resolution.status()
    assert r["connector"] == nil and r["modes"] == [] and r["preferred"] == nil and r["setting"] == "auto"
    assert_raise ArgumentError, fn -> Resolution.set("1280x720") end
  end

  test "a saved mode the screen no longer offers shows as auto" do
    Sys.write_atomic("/etc/alnasl/kiosk.conf", "KIOSK_RES=\"800x600\"\n")
    assert Resolution.status()["setting"] == "auto"
  end
end
