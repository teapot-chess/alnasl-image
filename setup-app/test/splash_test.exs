defmodule AlnaslSetup.SplashTest do
  # The boot screen painter (port of scripts/test-splash.py, plus the command line and the hold loop).
  #
  # Composes every state, in both languages, on fake framebuffers of the usual shapes (16/24/32 bpp,
  # 720p/1080p/4K, padded strides) and checks: the frame has the right size, the mark's accent square sits
  # where the probe says, a text state really differs from the plain screen, and every picture the browser
  # asks for (/splash/...) exists. The framebuffer, where one is needed, is a file under the fake root; the
  # ioctl helper (alnasl-fbtool) is faked through the command runner. No framebuffer, tty or X is touched.
  use ExUnit.Case, async: false
  alias AlnaslSetup.Splash
  alias AlnaslSetup.Sys
  alias AlnaslSetup.Test.Box

  @assets Path.expand("../../overlay/usr/share/alnasl/splash", __DIR__)

  # One fake root for the whole module, carrying a copy of the pictures (2 MB: not once per test).
  setup_all do
    root = Path.join(System.tmp_dir!(), "alnasl-splash-test-#{System.unique_integer([:positive])}")
    share = Path.join(root, "usr/share/alnasl/splash")
    File.mkdir_p!(Path.dirname(share))
    File.cp_r!(@assets, share)
    Application.put_env(:alnasl_setup, :root, root)

    on_exit(fn ->
      Application.delete_env(:alnasl_setup, :root)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  setup %{root: root} do
    # state files of one test must not leak into the next
    for d <- ["run", "var", "dev", "proc", "sys"], do: File.rm_rf!(Path.join(root, d))
    Application.delete_env(:alnasl_setup, :runner)
    Application.delete_env(:alnasl_setup, :journal_cmd)
    :ok
  end

  @states (@assets <> "/messages.json") |> File.read!() |> JSON.decode!() |> Map.fetch!("states")
  @shapes [{1920, 1080, 32, 0}, {1920, 1080, 16, 0}, {1280, 720, 32, 128}, {3840, 2160, 32, 0}, {1024, 768, 24, 0}]

  test "messages.json: the states, and the pictures the browser asks for" do
    assert map_size(@states) >= 10 and Map.has_key?(@states, "boot")
    share = Sys.path("/usr/share/alnasl/splash")

    for {key, st} <- @states, lang <- ["en", "nl"], st["text"] do
      assert File.regular?("#{share}/screens/#{lang}/#{key}.png"), "browser picture #{lang}/#{key}"

      for h <- [1080, 720] do
        assert File.regular?("#{share}/text/#{lang}/#{key}.#{h}.title.pgm"), "title #{lang}/#{key} #{h}"
      end
    end

    assert File.regular?(share <> "/alnasl-splash.png")

    for size <- [1080, 720] do
      assert File.regular?("#{share}/text/mono/#{size}.pgm")
      assert File.regular?("#{share}/screens/mono/#{size}.png")
    end
  end

  describe "compose" do
    test "frame size, accent square at the probe, text states differ from the plain screen" do
      for {w, h, bpp, pad} <- @shapes do
        fb = Splash.new_fb(w, h, bpp, pad)
        {plain, probe} = Splash.compose(fb, "boot", "en")
        assert byte_size(plain) == fb.stride * h, "#{w}x#{h} #{bpp}bpp: frame size"
        assert binary_part(plain, probe, fb.b) == Splash.px(fb, Splash.accent()), "#{w}x#{h} #{bpp}bpp: probe"

        for {key, st} <- @states, lang <- ["en", "nl"], st["text"] do
          {frame, _} = Splash.compose(fb, key, lang)
          assert frame != plain, "#{lang}/#{key} at #{w}x#{h} draws no text"
        end
      end
    end

    test "the mark: background outside, ink and accent squares inside (1080p, 32 bpp)" do
      fb = Splash.new_fb(1920, 1080, 32, 0)
      {frame, _} = Splash.compose(fb, "boot", "en")
      at = fn x, y -> binary_part(frame, y * fb.stride + x * 4, 4) end
      assert at.(0, 0) == Splash.px(fb, Splash.bg())
      # the mark's top left square: (cx - 150, cy - 150), 90 px
      assert at.(960 - 150, 540 - 150) == Splash.px(fb, Splash.ink())
      assert at.(960 - 150 + 89, 540 - 150 + 89) == Splash.px(fb, Splash.ink())
      assert at.(960 - 150 + 90, 540 - 150) == Splash.px(fb, Splash.bg())
      # the second one of the top row is ink, the third (column 2) is the accent one
      assert at.(960 + 60, 540 - 150) == Splash.px(fb, Splash.accent())
      # a gap
      assert at.(960 - 150 + 92, 540 - 150 + 10) == Splash.px(fb, Splash.bg())
      # little-endian packing: blue in the lowest byte, red third
      {bg_r, _, bg_b} = Splash.bg()
      assert <<^bg_b, _g, ^bg_r, _a>> = at.(0, 0)
    end

    test "16 bpp packs RGB565" do
      fb = Splash.new_fb(800, 480, 16, 0)
      assert Splash.px(fb, {0xFF, 0xFF, 0xFF}) == <<0xFF, 0xFF>>
      assert Splash.px(fb, {0xFF, 0, 0}) == <<0x00, 0xF8>>
      assert Splash.px(fb, {0, 0, 0xFF}) == <<0x1F, 0x00>>
    end

    test "progress bar and value line come from their arguments" do
      fb = Splash.new_fb(1920, 1080, 32, 0)
      {a, _} = Splash.compose(fb, "update-download", "en", val: "37%", prog: 10)
      {b, _} = Splash.compose(fb, "update-download", "en", val: "37%", prog: 90)
      {c, _} = Splash.compose(fb, "update-download", "en", val: "38%", prog: 10)
      assert a != b and a != c
    end

    test "the log changes the picture of the states that show it and nothing else" do
      lines = [
        {"kernel", "kernel", false, "usb 1-1: new high-speed USB device"},
        {"network", "network", false, "eth0: Gained carrier"},
        {"systemd", "error", true, "nunki.service: Failed with result 'exit-code'."},
        {"nunki", "app", false, "listening on 127.0.0.1:4062"}
      ]

      logv = {"starting nunki - 7 of 12 up", lines}

      for {w, h, bpp, pad} <- [{1920, 1080, 32, 0}, {800, 480, 16, 0}, {1280, 720, 32, 128}, {720, 720, 32, 0}, {1024, 600, 24, 0}] do
        fb = Splash.new_fb(w, h, bpp, pad)

        for key <- Splash.log_states(), Map.has_key?(@states, key) do
          {bare, _} = Splash.compose(fb, key, "en")
          {withlog, _} = Splash.compose(fb, key, "en", logv: logv)
          assert byte_size(withlog) == byte_size(bare) and withlog != bare, "#{key} at #{w}x#{h} #{bpp}bpp: the log is drawn"
          {y0, data} = Splash.log_region(fb, key, elem(logv, 0), lines)
          assert rem(byte_size(data), fb.stride) == 0
          assert binary_part(withlog, y0 * fb.stride, byte_size(data)) == data, "#{key} at #{w}x#{h}: region is whole rows"
        end

        for key <- ["update-restart", "reset-2", "shutdown"], Map.has_key?(@states, key) do
          {a, _} = Splash.compose(fb, key, "en")
          {b, _} = Splash.compose(fb, key, "en", logv: nil)
          assert a == b, "#{key} at #{w}x#{h}: v6's picture, no log"
        end
      end
    end

    test "the newest log line is at the bottom, errors do not fade" do
      fb = Splash.new_fb(1920, 1080, 32, 0)
      lines = for i <- 1..60, do: {"kernel", "kernel", false, "line number #{i}"}
      {y0, data} = Splash.log_region(fb, "boot", "up", lines)
      assert y0 > 0 and byte_size(data) > 0
      # fewer lines than the screen holds: the extra ones are cut from the top, the rows are still whole
      {_, few} = Splash.log_region(fb, "boot", "up", Enum.take(lines, -3))
      assert byte_size(few) == byte_size(data)
      assert few != data
    end
  end

  describe "the command line" do
    defp fbtool_runner(w, h, bpp) do
      Box.runner!(fn
        [_tool, "vinfo", _fb] ->
          {0,
           "xres=#{w}\nyres=#{h}\nyoffset=0\nbits_per_pixel=#{bpp}\n" <>
             "red_offset=16\nred_length=8\ngreen_offset=8\ngreen_length=8\nblue_offset=0\nblue_length=8\n"}

        [_tool, "graphics", _tty] ->
          {0, ""}

        _ ->
          nil
      end)
    end

    defp fake_fb(w, h, bpp) do
      Box.put("/dev/fb0", :binary.copy(<<0>>, w * h * div(bpp, 8)))
      Sys.path("/dev/fb0")
    end

    test "--set writes the state, rejects unknown ones, clear removes it" do
      assert Splash.main(["--set", "reboot"]) == 0
      assert Sys.read("/run/alnasl-screen/state") == "reboot\n"
      assert Splash.main(["--set", "nonsense"]) == 2
      assert Sys.read("/run/alnasl-screen/state") == "reboot\n"
      assert Splash.main(["--set", "clear"]) == 0
      refute Sys.exists?("/run/alnasl-screen/state")
      assert Splash.main(["--set", "clear"]) == 0
    end

    test "--value and --progress validate and clear" do
      assert Splash.main(["--value", "37%"]) == 0
      assert Sys.read("/run/alnasl-screen/value") == "37%\n"
      assert Splash.main(["--value", "v6.2"]) == 0
      assert Splash.main(["--value", "37 %"]) == 2
      assert Splash.main(["--value", "1234567890123"]) == 2
      assert Splash.main(["--value", "clear"]) == 0
      refute Sys.exists?("/run/alnasl-screen/value")

      assert Splash.main(["--progress", "42"]) == 0
      assert Sys.read("/run/alnasl-screen/progress") == "42\n"
      assert Splash.main(["--progress", "101"]) == 2
      assert Splash.main(["--progress", "abc"]) == 2
      assert Splash.main(["--progress", "clear"]) == 0
      refute Sys.exists?("/run/alnasl-screen/progress")
    end

    test "--next writes the next-boot state without painting" do
      assert Splash.main(["--next", "update-finish"]) == 0
      assert Sys.read("/var/lib/alnasl-screen/next-boot") == "update-finish\n"
      assert Splash.main(["--next", "bogus"]) == 2
      assert Splash.main(["--next", "clear"]) == 0
      refute Sys.exists?("/var/lib/alnasl-screen/next-boot")
    end

    test "usage on anything else" do
      assert Splash.main([]) == 2
      assert Splash.main(["--bogus"]) == 2
      assert Splash.main(["--shutdown", "sideways"]) == 2
    end

    test "--once paints the state's frame into the framebuffer, with tty1 in graphics mode" do
      fbtool_runner(640, 360, 32)
      fb_path = fake_fb(640, 360, 32)
      Box.put("/run/alnasl-screen/state", "reboot\n")
      assert Splash.main(["--once"]) == 0
      fb = Splash.new_fb(640, 360, 32, 0)
      {frame, _} = Splash.compose(fb, "reboot", "en")
      assert File.read!(fb_path) == frame
      ran = Box.ran()
      assert Enum.any?(ran, &match?([_, "vinfo", _], &1))
      assert Enum.any?(ran, &match?([_, "graphics", _], &1))
    end

    test "the sysfs stride, the language from state.json and the vertical offset are honoured" do
      Box.runner!(fn
        [_, "vinfo", _] ->
          {0,
           "xres=320\nyres=200\nyoffset=2\nbits_per_pixel=16\nred_offset=0\nred_length=0\n" <>
             "green_offset=0\ngreen_length=0\nblue_offset=0\nblue_length=0\n"}

        _ ->
          nil
      end)

      Box.put("/sys/class/graphics/fb0/stride", "800\n")
      Box.put("/var/lib/alnasl-setup/state.json", ~s({"lang": "nl"}))
      Box.put("/run/alnasl-screen/state", "reboot\n")
      path = Box.put("/dev/fb0", :binary.copy(<<0>>, 800 * 202 + 800 * 200))
      assert Splash.main(["--once"]) == 0
      # an empty layout from the driver means RGB565
      fb = %{Splash.new_fb(320, 200, 16, 0) | stride: 800}
      {frame, _} = Splash.compose(fb, "reboot", "nl")
      data = File.read!(path)
      assert binary_part(data, 2 * 800, byte_size(frame)) == frame
      assert binary_part(data, 0, 2 * 800) == :binary.copy(<<0>>, 1600)
    end

    test "nothing is painted while X runs, or when tty1 is not the active VT" do
      fbtool_runner(320, 200, 32)
      path = fake_fb(320, 200, 32)
      zero = File.read!(path)
      Box.put("/proc/77/comm", "Xorg\n")
      assert Splash.main(["--once"]) == 0
      assert File.read!(path) == zero
      File.rm_rf!(Sys.path("/proc"))
      Box.put("/proc/78/comm", "cage\n")
      assert Splash.main(["--once"]) == 0
      assert File.read!(path) == zero
      File.rm_rf!(Sys.path("/proc"))
      Box.put("/proc/79/comm", "bash\n")
      Box.put("/sys/class/tty/tty0/active", "tty2\n")
      assert Splash.main(["--once"]) == 0
      assert File.read!(path) == zero
      Box.put("/sys/class/tty/tty0/active", "tty1\n")
      assert Splash.main(["--once"]) == 0
      assert File.read!(path) != zero
    end

    test "--shutdown paints the reason that was given, else reboot or shutdown" do
      fbtool_runner(320, 200, 32)
      path = fake_fb(320, 200, 32)
      fb = Splash.new_fb(320, 200, 32, 0)
      assert Splash.main(["--shutdown", "poweroff"]) == 0
      assert File.read!(path) == elem(Splash.compose(fb, "shutdown", "en"), 0)
      assert Splash.main(["--shutdown", "reboot"]) == 0
      assert File.read!(path) == elem(Splash.compose(fb, "reboot", "en"), 0)
      Box.put("/run/alnasl-screen/state", "reset-3\n")
      assert Splash.main(["--shutdown", "poweroff"]) == 0
      assert File.read!(path) == elem(Splash.compose(fb, "reset-3", "en"), 0)
      # "waiting" is not a reason
      Box.put("/run/alnasl-screen/state", "waiting\n")
      assert Splash.main(["--shutdown", "poweroff"]) == 0
      assert File.read!(path) == elem(Splash.compose(fb, "shutdown", "en"), 0)
    end
  end

  describe "--hold" do
    test "returns at once when X has the screen, and drops the next-boot state" do
      Box.put("/proc/5/comm", "Xorg\n")
      Box.put("/var/lib/alnasl-screen/next-boot", "update-finish\n")
      assert Splash.main(["--hold"]) == 0
      refute Sys.exists?("/var/lib/alnasl-screen/next-boot")
    end

    @tag :unix
    test "paints, repaints what was wiped, and stops when X appears" do
      Box.runner!(fn
        [_, "vinfo", _] ->
          {0, "xres=320\nyres=200\nyoffset=0\nbits_per_pixel=32\nred_offset=16\nred_length=8\ngreen_offset=8\ngreen_length=8\nblue_offset=0\nblue_length=8\n"}

        [_, "graphics", _] ->
          {0, ""}

        ["systemctl" | _] ->
          {0, ""}
      end)

      Application.put_env(:alnasl_setup, :journal_cmd, ["sleep", "30"])
      path = fake_fb(320, 200, 32)
      Box.put("/run/alnasl-screen/state", "reboot\n")
      task = Task.async(fn -> Splash.main(["--hold"]) end)
      fb = Splash.new_fb(320, 200, 32, 0)
      {frame, _} = Splash.compose(fb, "reboot", "en")
      assert wait_for(fn -> File.read!(path) == frame end)
      # the firmware's framebuffer replaced: the accent pixel is gone, the painter paints again
      File.write!(path, :binary.copy(<<0>>, byte_size(frame)))
      assert wait_for(fn -> File.read!(path) == frame end)
      Box.put("/proc/9/comm", "Xorg\n")
      assert Task.await(task, 5000) == 0
    end

    defp wait_for(fun, tries \\ 100) do
      cond do
        fun.() -> true
        tries == 0 -> false
        true -> Process.sleep(50) && wait_for(fun, tries - 1)
      end
    end
  end
end
