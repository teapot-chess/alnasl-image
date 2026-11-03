defmodule AlnaslSetup.SmallScreenTest do
  # The small screens on the pins (AlnaslSetup.SmallScreen): the alnasl-screen.txt parser, which overlays and
  # modules a boot asks for, the calibration maths, and what a boot writes, all without a panel, an SPI bus or a
  # kernel that cooperates. (Ported from touch-wip's test-touch.py and extended to the SPI panels.)
  use ExUnit.Case, async: false
  alias AlnaslSetup.SmallScreen, as: S
  alias AlnaslSetup.{Json, Sys, Test.Box}

  @template Path.expand("../../overlay/boot-efi/alnasl-screen.txt", __DIR__)
  @pi4 %{spi_pins: true, spidev0: true, spidev1: true}
  @pi3 %{spi_pins: false, spidev0: false, spidev1: false}

  defp close?(a, b, tol \\ 1.0e-6),
    do: Enum.zip(Tuple.to_list(a), Tuple.to_list(b)) |> Enum.all?(fn {x, y} -> abs(x - y) <= tol end)

  describe "the file" do
    test "no file, an empty one, the shipped one: hdmi, nothing to do" do
      for d <- [nil, "", File.read!(@template)] do
        p = S.parse(d)
        assert p.screen == "hdmi" and p.preset == nil and p.touch == "off" and p.rotate == 0 and p.mode == "640x480"
        assert S.plan(p, @pi4) == %{overlays: [], modules: [], driver: nil}
      end

      assert S.parse(nil).problems == ["no file"]
      assert S.parse(File.read!(@template)).problems == []
    end

    test "the presets, their aliases, CRLF, a BOM, lower case and spaces" do
      assert S.parse("SCREEN=waveshare35a\r\nROTATE=180\r\n") |> Map.take([:screen, :preset, :touch, :rotate]) ==
               %{screen: "waveshare35a", preset: "waveshare35a", touch: "xpt2046", rotate: 180}

      assert S.parse("﻿screen = PiScreen \n").preset == "waveshare35a"
      assert S.parse("SCREEN=waveshare32b\n").preset == "waveshare32b"
      p = S.parse("SCREEN=hx8357d\n")
      assert p.preset == "hx8357d" and p.touch == "off"
    end

    test "the 3.5-inch HDMI screen with stylus: TOUCH=xpt2046 (touch-wip's file), or SCREEN=mpi3508" do
      for d <- [
            "TOUCH=xpt2046\nMODE=480x320\n",
            "SCREEN=hdmi\nTOUCH=ads7846\nMODE=480x320\n",
            "SCREEN=mpi3508\nTOUCH=off\nMODE=480x320\n"
          ] do
        p = S.parse(d)
        assert p.screen == "hdmi" and p.preset == "hdmi-xpt2046" and p.touch == "xpt2046" and p.mode == "480x320", d
      end

      assert S.parse("SCREEN=hdmi\nTOUCH=off\n").preset == nil
      assert S.parse("TOUCH=uit\n").preset == nil
    end

    test "nonsense falls back to the safe value, with a complaint, and the rest still counts" do
      p = S.parse("SCREEN=ili9999\nTOUCH=maybe\nROTATE=45\nMODE=1920x1080\n")
      assert p.screen == "hdmi" and p.preset == nil and p.rotate == 0 and p.mode == "640x480"
      assert length(p.problems) == 4

      p = S.parse("SCREEN=waveshare35a\nROTATE=45\n")
      assert p.preset == "waveshare35a" and p.rotate == 0 and length(p.problems) == 1
      assert S.parse("SCREEN=waveshare35a\nSCREEN=hdmi\n").preset == "waveshare35a"
      assert S.parse("# SCREEN=waveshare35a\n").preset == nil
    end

    test "a damaged card is not trusted: NUL bytes, 64 KiB and more, random bytes" do
      assert S.parse("SCREEN=waveshare35a\n\0\0\0").preset == nil
      assert S.parse("SCREEN=waveshare35a\n" <> String.duplicate("#", 65_546)).preset == nil
      :rand.seed(:exsss, {7, 7, 7})
      junk = for _ <- 1..3000, into: <<>>, do: <<:rand.uniform(256) - 1>>
      assert S.parse(junk).preset == nil
    end

    test "CALIBRATION= and SWAPXY=: read, refused when absurd, swap defaults to the screen's" do
      assert S.parse("SCREEN=waveshare35a\nCALIBRATION=390 3750 3700 400\n").manual == {390, 3750, 3700, 400, false}
      assert S.parse("TOUCH=xpt2046\nCALIBRATION=3945,233,3939,183\n").manual == {3945, 233, 3939, 183, true}
      assert S.parse("TOUCH=xpt2046\nCALIBRATION=200 3900 200 3900\nSWAPXY=0\n").manual == {200, 3900, 200, 3900, false}

      for bad <- ["1 2 3", "0 4096 0 4000", "100 150 0 4000", "a b c d"] do
        p = S.parse("SCREEN=waveshare35a\nCALIBRATION=#{bad}\n")
        assert p.manual == nil and p.preset == "waveshare35a" and p.problems != [], bad
      end
    end

    test "the shipped file with a preset typed in" do
      t = File.read!(@template)
      assert S.parse(String.replace(t, "\nSCREEN=hdmi", "\nSCREEN=waveshare35a")).preset == "waveshare35a"
      assert S.parse(String.replace(t, "\nTOUCH=auto", "\nTOUCH=xpt2046")).preset == "hdmi-xpt2046"
    end
  end

  describe "the plan" do
    test "waveshare35a on a Pi 4: both spidevs off, then the panel at its rotation; spi, mipi-dbi, ili9486, ads7846" do
      assert S.plan(S.parse("SCREEN=waveshare35a\n"), @pi4) == %{
               overlays: ["alnasl-spidev0-off", "alnasl-spidev1-off", "alnasl-waveshare35a-r0"],
               modules: ~w(spi-bcm2835 drm_mipi_dbi ili9486 ads7846),
               driver: "ili9486"
             }

      assert List.last(S.plan(S.parse("SCREEN=waveshare35a\nROTATE=270\n"), @pi4).overlays) ==
               "alnasl-waveshare35a-r270"
    end

    test "a mainline (Pi 3) tree: no spidev nodes to switch off, the SPI pins first" do
      assert S.plan(S.parse("SCREEN=waveshare35a\n"), @pi3).overlays == ["alnasl-spi0-pins", "alnasl-waveshare35a-r0"]
    end

    test "the portrait panels are landscape at ROTATE=0 (driver rotation 90), and turn from there" do
      assert List.last(S.plan(S.parse("SCREEN=waveshare32b\n"), @pi4).overlays) == "alnasl-waveshare32b-r90"
      assert List.last(S.plan(S.parse("SCREEN=waveshare32b\nROTATE=270\n"), @pi4).overlays) == "alnasl-waveshare32b-r0"
      p = S.plan(S.parse("SCREEN=hx8357d\nROTATE=90\n"), @pi4)
      assert List.last(p.overlays) == "alnasl-hx8357d-r180" and "ads7846" not in p.modules
    end

    test "the HDMI stylus screen leaves chip select 0 alone" do
      assert S.plan(S.parse("TOUCH=xpt2046\n"), @pi4) == %{
               overlays: ["alnasl-spidev1-off", "alnasl-xpt2046"],
               modules: ~w(spi-bcm2835 ads7846),
               driver: nil
             }
    end

    test "every overlay a plan can name is in all_overlays/0" do
      named =
        for s <- ~w(waveshare35a waveshare32b hx8357d mpi3508),
            r <- [0, 90, 180, 270],
            t <- [@pi3, @pi4],
            o <- S.plan(S.parse("SCREEN=#{s}\nROTATE=#{r}\n"), t).overlays,
            uniq: true,
            do: o

      assert Enum.sort(named) == S.all_overlays()
      assert length(S.all_overlays()) == 16
    end

    test "the kiosk's settings: an SPI panel names its card, an HDMI stylus screen its mode and rotation" do
      assert S.kiosk_env(S.parse("SCREEN=waveshare35a\nROTATE=90\n"), "card1", "/dev/fb1") ==
               ~s(KIOSK_CARD="card1"\nKIOSK_FB="/dev/fb1"\nKIOSK_FORCE_MODE=""\nKIOSK_ROTATE="normal"\n)

      assert S.kiosk_env(S.parse("TOUCH=xpt2046\nROTATE=90\n")) ==
               ~s(KIOSK_CARD=""\nKIOSK_FB=""\nKIOSK_FORCE_MODE="640x480"\nKIOSK_ROTATE="right"\n)

      assert S.kiosk_env(S.parse("TOUCH=xpt2046\nMODE=auto\n")) =~ ~s(KIOSK_FORCE_MODE=""\n)
    end
  end

  describe "the matrices" do
    test "invert, and the four rotations take the corners where a clockwise turn puts them" do
      m = {1.2, -0.1, 0.05, 0.2, 0.9, -0.03}
      assert close?(S.compose(m, S.invert(m)), S.identity()) and close?(S.compose(S.invert(m), m), S.identity())
      # the picture turned 90 degrees clockwise: its top-left corner is the panel's top-right, and so on
      assert S.transform(S.rotation(90), 1.0, 0.0) == {0.0, 0.0}
      assert S.transform(S.rotation(180), 1.0, 1.0) == {0.0, 0.0}
      assert S.transform(S.rotation(270), 0.0, 1.0) == {0.0, 0.0}
      r = S.compose(S.rotation(90), S.compose(S.rotation(90), S.compose(S.rotation(90), S.rotation(90))))
      assert close?(r, S.identity())
    end

    test "waveshare35a's built-in values put the measured corners on the screen's corners" do
      {c, "default"} = S.effective(S.parse("SCREEN=waveshare35a\n"), nil)
      # TL, TR, BR, BL as tapped on the real panel
      for {{rx, ry}, {tx, ty}} <- [
            {{356, 3693}, {0, 0}},
            {{3749, 3597}, {1, 0}},
            {{3753, 582}, {1, 1}},
            {{423, 409}, {0, 1}}
          ] do
        {x, y} = S.transform(c, rx / 4096, ry / 4096)
        assert abs(x - tx) < 0.06 and abs(y - ty) < 0.06, inspect({rx, ry, x, y})
      end
    end

    test "the vendor's MPI3508 numbers, the file's over them, the screen's over both" do
      cfg = S.parse("TOUCH=xpt2046\n")
      {c, "default"} = S.effective(cfg, nil)
      assert close?(c, S.evdev_matrix({3945, 233, 3939, 183, true}))
      {_, "file"} = S.effective(S.parse("TOUCH=xpt2046\nCALIBRATION=200 3900 200 3900\n"), nil)
      {s, "screen"} = S.effective(cfg, {1.0, 0.0, 0.0, 0.0, 1.0, 0.0})
      assert s == S.identity()
      {_, "default"} = S.effective(cfg, {0.0, 0.0, 0.0, 0.0, 0.0, 0.0})
    end

    test "calibrate: taps made with a wrong matrix give back the right one, in the panel's frame" do
      for rot <- [0, 90, 180, 270] do
        truth = S.evdev_matrix({300, 3800, 3600, 500, false})
        wrong = S.evdev_matrix({390, 3750, 3700, 400, false})
        # what X uses: the rotation after the calibration
        cur = S.compose(S.rotation(rot), wrong)
        true_full = S.compose(S.rotation(rot), truth)

        samples =
          for {tx, ty} <- [{0.15, 0.15}, {0.85, 0.15}, {0.85, 0.85}, {0.15, 0.85}] do
            {rx, ry} = S.transform(S.invert(true_full), tx, ty)
            {ox, oy} = S.transform(cur, rx, ry)
            [tx, ty, ox, oy]
          end

        {c, res} = S.calibrate(samples, cur, rot)
        assert res < 1.0e-6 and close?(c, truth, 1.0e-6), "rotation #{rot}"
      end
    end

    test "calibrate refuses what a person must redo" do
      cur = S.identity()
      assert_raise ArgumentError, "four taps are needed", fn -> S.calibrate([[0.1, 0.1, 0.1, 0.1]], cur, 0) end

      assert_raise ArgumentError, "a tap is four numbers", fn ->
        S.calibrate(List.duplicate(["a", 1, 1, 1], 4), cur, 0)
      end

      assert_raise ArgumentError, "a tap outside the screen", fn ->
        S.calibrate(List.duplicate([0.5, 0.5, 2.0, 0.5], 4), cur, 0)
      end

      # one tap on the wrong cross
      bad = [[0.15, 0.15, 0.15, 0.15], [0.85, 0.15, 0.85, 0.15], [0.85, 0.85, 0.85, 0.85], [0.15, 0.85, 0.6, 0.4]]
      assert_raise ArgumentError, ~r/do not line up/, fn -> S.calibrate(bad, cur, 0) end
      # all four on one spot
      assert_raise ArgumentError, fn -> S.calibrate(List.duplicate([0.5, 0.5, 0.5, 0.5], 4), cur, 0) end
    end

    test "the udev rule names the controller and carries six numbers" do
      r = S.udev_rule(S.identity())
      assert r =~ ~s(ATTRS{name}=="ADS7846 Touchscreen")
      assert r =~ ~s(ENV{LIBINPUT_CALIBRATION_MATRIX}="1.000000 0.000000 0.000000 0.000000 1.000000 0.000000")
    end

    test "the udev rule makes the stylus a touchscreen only (a pointer or touchpad moves but never clicks)" do
      r = S.udev_rule(S.identity())
      assert r =~ ~s(ENV{ID_INPUT_TOUCHSCREEN}="1")

      for tag <- ~w(ID_INPUT_TOUCHPAD ID_INPUT_TABLET ID_INPUT_MOUSE ID_INPUT_JOYSTICK),
          do: assert(r =~ ~s(ENV{#{tag}}=""))

      # one rule line, so udev applies it all to the same device
      assert r |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#")) |> length() == 1
    end
  end

  describe "a boot" do
    setup do
      Box.root!()
      Application.put_env(:alnasl_setup, :small_screen_poll_ms, 1)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :small_screen_poll_ms) end)
      Box.runner!(fn _ -> {0, ""} end)
      Box.put("/boot/efi/.keep", "")
      :ok
    end

    defp state, do: Json.decode_or_nil(Sys.read(S.state_file()))

    test "SCREEN=hdmi touches nothing: no modprobe, no configfs, no rule, no kiosk settings" do
      Box.put("/boot/efi/alnasl-screen.txt", File.read!(@template))
      Box.put("/run/udev/rules.d/90-alnasl-touch.rules", "old")
      Box.put("/run/alnasl-small-screen/kiosk.env", "KIOSK_CARD=\"card1\"\n")
      assert S.main([]) == 0
      assert Box.ran() == []
      assert state()["status"] == "off" and state()["screen"] == "hdmi"
      refute Sys.exists?("/run/udev/rules.d/90-alnasl-touch.rules")
      refute Sys.exists?("/run/alnasl-small-screen/kiosk.env")
      refute Sys.exists?("/sys/kernel/config/device-tree")
      refute S.forced?()
    end

    test "a missing file comes back from the template, and means hdmi" do
      Box.put("/usr/share/alnasl/defaults/boot-efi/alnasl-screen.txt", File.read!(@template))
      assert S.main([]) == 0
      assert Sys.read("/boot/efi/alnasl-screen.txt") == File.read!(@template)
      assert state()["status"] == "off" and Box.ran() == []
    end

    test "no configfs overlays in the kernel: a state that says so, the kiosk on HDMI" do
      Box.put("/boot/efi/alnasl-screen.txt", "SCREEN=waveshare35a\n")
      assert S.main([]) == 0
      assert state()["status"] == "no_overlay_support"
      assert Sys.read("/run/alnasl-small-screen/kiosk.env") =~ ~s(KIOSK_CARD=""\n)
      assert ["mount", "-t", "configfs", "configfs", "/sys/kernel/config"] in Box.ran()
    end

    defp pi4_tree do
      Box.put("/proc/device-tree/__symbols__/spi", "/soc/spi@7e204000\0")
      Box.put("/proc/device-tree/soc/spi@7e204000/pinctrl-0", "x")
      Box.put("/proc/device-tree/soc/spi@7e204000/spidev@0/status", "okay")
      Box.put("/proc/device-tree/soc/spi@7e204000/spidev@1/status", "okay")
    end

    # configfs as the kernel leaves it after a write: the directory with status "applied"
    defp applied(names),
      do: for(n <- names, do: Box.put("/sys/kernel/config/device-tree/overlays/#{n}/status", "applied\n"))

    @tag :unix
    test "waveshare35a: overlays, modules, the panel unblanked and named to the kiosk, the stylus calibrated" do
      Box.put("/boot/efi/alnasl-screen.txt", "SCREEN=waveshare35a\n")
      pi4_tree()
      applied(~w(alnasl-spidev0-off alnasl-spidev1-off alnasl-waveshare35a-r0))
      Box.put("/sys/bus/spi/drivers/ili9486/.keep", "")
      Box.put("/sys/class/drm/card0/device/.keep", "")
      Box.put("/sys/class/drm/card1/device/.keep", "")
      File.ln_s!(Sys.path("/sys/bus/spi/drivers/ili9486"), Sys.path("/sys/class/drm/card1/device/driver"))
      Box.put("/sys/class/graphics/fb0/name", "vc4drmfb\n")
      Box.put("/sys/class/graphics/fb1/name", "ili9486drmfb\n")
      Box.put("/sys/class/graphics/fb1/blank", "")
      Box.put("/sys/class/input/event0/device/name", "ADS7846 Touchscreen\n")

      assert S.main([]) == 0
      st = state()

      assert st["status"] == "ready" and st["card"] == "card1" and st["fb"] == "fb1" and
               st["device"] == "/dev/input/event0"

      assert st["overlays"] == ~w(alnasl-spidev0-off alnasl-spidev1-off alnasl-waveshare35a-r0) and
               st["source"] == "default"

      assert Sys.read("/sys/class/graphics/fb1/blank") == "0"
      assert Sys.read("/run/alnasl-small-screen/kiosk.env") =~ ~s(KIOSK_CARD="card1"\nKIOSK_FB="/dev/fb1"\n)
      mods = for ["modprobe", m] <- Box.ran(), do: m
      assert mods == ~w(spi-bcm2835 drm_mipi_dbi ili9486 ads7846)
      assert Sys.read("/run/udev/rules.d/90-alnasl-touch.rules") =~ "LIBINPUT_CALIBRATION_MATRIX"
      assert S.forced?()

      # the on-screen calibration: saved for this screen, a new rule; reset takes it away again
      old = Sys.read("/run/udev/rules.d/90-alnasl-touch.rules")
      cur = List.to_tuple(st["matrix"])
      truth = S.evdev_matrix({300, 3800, 3600, 500, false})

      samples =
        for {tx, ty} <- [{0.15, 0.15}, {0.85, 0.15}, {0.85, 0.85}, {0.15, 0.85}] do
          {rx, ry} = S.transform(S.invert(truth), tx, ty)
          {ox, oy} = S.transform(cur, rx, ry)
          [tx, ty, ox, oy]
        end

      {_c, res} = S.save_calibration(samples)
      assert res < 1.0e-5
      saved = Json.decode_or_nil(Sys.read("/var/lib/alnasl-setup/touch-calibration.json"))
      assert saved["screen"] == "waveshare35a" and length(saved["matrix"]) == 6
      assert state()["source"] == "screen" and Sys.read("/run/udev/rules.d/90-alnasl-touch.rules") != old
      assert S.status()["stored"] == true
      S.reset_calibration()
      refute Sys.exists?("/var/lib/alnasl-setup/touch-calibration.json")
      assert state()["source"] == "default" and Sys.read("/run/udev/rules.d/90-alnasl-touch.rules") == old
    end

    test "the overlays go in but no panel answers: no_panel, and the kiosk stays on HDMI" do
      Box.put("/boot/efi/alnasl-screen.txt", "SCREEN=hx8357d\n")
      pi4_tree()
      applied(~w(alnasl-spidev0-off alnasl-spidev1-off alnasl-hx8357d-r90))
      assert S.main([]) == 0
      assert state()["status"] == "no_panel" and state()["card"] == nil
      assert Sys.read("/run/alnasl-small-screen/kiosk.env") =~ ~s(KIOSK_CARD=""\n)
      refute Sys.exists?("/run/udev/rules.d/90-alnasl-touch.rules")
      refute S.forced?()
    end

    test "an overlay the kernel refuses stops there: nothing loaded" do
      Box.put("/boot/efi/alnasl-screen.txt", "SCREEN=waveshare35a\n")
      pi4_tree()
      Box.put("/sys/kernel/config/device-tree/overlays/alnasl-spidev0-off/status", "unapplied\n")
      assert S.main([]) == 0
      assert state()["status"] == "overlay_failed" and state()["overlay"] == "alnasl-spidev0-off"
      assert for(["modprobe" | _] = c <- Box.ran(), do: c) == []
    end

    test "a calibration from another screen is not used, and a stylus screen that is off refuses one" do
      Box.put(
        "/var/lib/alnasl-setup/touch-calibration.json",
        ~s({"screen": "hdmi-xpt2046", "matrix": [1, 0, 0, 0, 1, 0]})
      )

      Box.put("/boot/efi/alnasl-screen.txt", "SCREEN=waveshare35a\n")
      pi4_tree()
      assert S.main([]) == 0
      assert state()["source"] == "default"
      Box.put("/boot/efi/alnasl-screen.txt", "SCREEN=hdmi\n")
      S.main([])

      assert_raise ArgumentError, ~r/touch screen is off/, fn ->
        S.save_calibration(List.duplicate([0.5, 0.5, 0.5, 0.5], 4))
      end
    end
  end
end
