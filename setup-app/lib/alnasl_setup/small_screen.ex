defmodule AlnaslSetup.SmallScreen do
  @moduledoc """
  alnasl-small-screen: the small screens that sit on the Pi's pins (v7.3; docs/spi-screens.md).

      alnasl-small-screen            at boot (alnasl-small-screen.service): read alnasl-screen.txt, switch the
                                     screen on or leave everything as it is
      alnasl-small-screen --status   what the box did, as JSON

  Two kinds, both opt-in (nothing can probe an SPI panel or a touch controller safely), both chosen in the boot
  partition's alnasl-screen.txt:

    * `SCREEN=waveshare35a` (alias `piscreen`), `waveshare32b`, `hx8357d`: a panel that takes its picture over
      SPI0, driven by a drm/tiny driver, mostly with an XPT2046 stylus touch on the same bus.
    * `SCREEN=hdmi` with `TOUCH=xpt2046`: a 3.5-inch screen that takes its picture over HDMI and has only its
      stylus touch on the pins (the CUQI RPM-01 / MPI3508 type; alias `SCREEN=mpi3508`).

  `SCREEN=hdmi` without touch, a missing file, a damaged one: nothing happens, SPI stays off, its pins free.

  How it gets there:
    * the device tree: the firmware builds it from config.txt, which is on the shared boot partition and is
      never touched by an A/B update. So the overlays go in HERE, at run time, through configfs
      (CONFIG_OF_CONFIGFS): alnasl-spidev0-off / alnasl-spidev1-off (only when the tree has those nodes, the
      Pi 4's does), alnasl-spi0-pins (only a tree whose SPI node has no pins, the Pi 3's mainline one), then the
      screen's own (`alnasl-<preset>-r<rotation>` or `alnasl-xpt2046`). Then the modules, built for this kernel.
    * the panel's picture: a drm/tiny driver sends the panel its init sequence only when its display pipe is
      enabled, and with fbcon on HDMI nothing enables it: a white panel, a healthy driver. So the panel's fb is
      unblanked here (the pipe goes on), and the kiosk is told which card to open (/run/alnasl-small-screen/kiosk.env:
      KIOSK_CARD, KIOSK_FB), so X really drives it. The rotation is the driver's (the overlay's `rotation`).
    * the stylus: a udev rule in /run gives the device LIBINPUT_CALIBRATION_MATRIX, which libinput in the
      kiosk's X server reads through the host's /run/udev. The matrix is rotation x calibration, so the picture
      and the stylus turn together.
    * an HDMI screen with stylus: the kiosk forces its mode (MODE=, 640x480 by default: the panel's bridge
      scales it and a Pi 4's HDMI will not go as slow as 480x320 needs) and turns it with xrandr.

  Calibration: the preset's numbers, CALIBRATION= in the file over those, the on-screen calibration (Settings >
  Touch screen, four crosses) over both. That one lives on the data partition, for the screen it was made on.
  Whatever the file says, a box boots: this never fails, and anything it cannot read means SCREEN=hdmi.
  """

  alias AlnaslSetup.{Json, Sys}

  @boot_file "/boot/efi/alnasl-screen.txt"
  @template "/usr/share/alnasl/defaults/boot-efi/alnasl-screen.txt"
  @cal_file "/var/lib/alnasl-setup/touch-calibration.json"
  @run "/run/alnasl-small-screen"
  @state_file @run <> "/state.json"
  @kiosk_env @run <> "/kiosk.env"
  @rule "/run/udev/rules.d/90-alnasl-touch.rules"
  @dtbo_dir "/usr/lib/alnasl/overlays"
  @cfs_root "/sys/kernel/config"
  @cfs @cfs_root <> "/device-tree/overlays"
  @dt "/proc/device-tree"
  @spi_node "/soc/spi@7e204000"
  # what the ads7846 driver calls an XPT2046 (model 7846)
  @touch_name "ADS7846 Touchscreen"
  @max_file 65_536
  # libinput normalises an axis by (max - min + 1); the driver's axes are 0..4095
  @range 4096.0

  # The presets. `base`: the driver rotation that is this box's ROTATE=0 (landscape, the right way up as the
  # board is usually mounted). `cal`: the stylus in evdev terms for ROTATE=0 (x min, x max, y min, y max, swap
  # axes), the raw values the driver reports (after the overlay's ti,swap-xy where it has one).
  # waveshare35a: measured on the real thing (x 390 left .. 3750 right, y 3700 top .. 400 bottom). waveshare32b:
  # the usual XPT2046 margins in the same orientation, a guess until somebody holds one. hdmi-xpt2046: the
  # vendor's 99-calibration.conf-3508-0 ("3945 233 3939 183", SwapAxes 1).
  @presets %{
    "waveshare35a" => %{
      kind: :spi,
      overlay: "alnasl-waveshare35a",
      base: 0,
      driver: "ili9486",
      modules: ~w(spi-bcm2835 drm_mipi_dbi ili9486 ads7846),
      touch: true,
      size: "480x320",
      cal: {390, 3750, 3700, 400, false}
    },
    "waveshare32b" => %{
      kind: :spi,
      overlay: "alnasl-waveshare32b",
      base: 90,
      driver: "ili9341",
      modules: ~w(spi-bcm2835 drm_mipi_dbi ili9341 ads7846),
      touch: true,
      size: "320x240",
      cal: {200, 3900, 3900, 200, false}
    },
    "hx8357d" => %{
      kind: :spi,
      overlay: "alnasl-hx8357d",
      base: 90,
      driver: "hx8357d",
      modules: ~w(spi-bcm2835 drm_mipi_dbi hx8357d),
      touch: false,
      size: "480x320",
      cal: nil
    },
    "hdmi-xpt2046" => %{
      kind: :hdmi_touch,
      overlay: "alnasl-xpt2046",
      base: 0,
      driver: nil,
      modules: ~w(spi-bcm2835 ads7846),
      touch: true,
      size: nil,
      cal: {3945, 233, 3939, 183, true}
    }
  }
  @aliases %{"piscreen" => "waveshare35a", "waveshare35" => "waveshare35a", "mpi3508" => "hdmi"}
  @hdmi_words ~w(hdmi off none no nee uit 0)
  @touch_on ~w(xpt2046 ads7846 on yes ja 1)
  @touch_off ~w(off uit no nee 0 none)
  @modes ~w(640x480 480x320 auto)
  @default_mode "640x480"
  # clockwise, as xrandr names it
  @xrandr %{0 => "normal", 90 => "right", 180 => "inverted", 270 => "left"}

  def presets, do: @presets
  def boot_file, do: @boot_file
  def state_file, do: @state_file

  defp log(msg), do: Sys.log("alnasl-small-screen", msg)

  # ------------------------------------------------------------------------------------ the file --

  @doc """
  What alnasl-screen.txt says, from its bytes (nil: no file). Pure, never raises: a file nobody can read says
  SCREEN=hdmi. The first line of each key counts.

  `%{screen, preset, touch, rotate, mode, manual, ui, problems}`: `screen` is the word the box acts on ("hdmi" or
  a preset), `preset` the key of `presets/0` in use (nil for a plain HDMI screen), `touch` "xpt2046" or "off".
  """
  def parse(data) do
    out = %{
      screen: "hdmi",
      preset: nil,
      touch: "off",
      rotate: 0,
      mode: @default_mode,
      manual: nil,
      ui: "auto",
      problems: []
    }

    cond do
      data == nil ->
        %{out | problems: ["no file"]}

      not is_binary(data) or byte_size(data) > @max_file or String.contains?(data, <<0>>) ->
        %{out | problems: ["not a text file"]}

      true ->
        text = if String.valid?(data), do: data, else: :unicode.characters_to_binary(data, :latin1)
        parse_keys(out, keys(text))
    end
  end

  defp keys(text) do
    text
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.reduce(%{}, fn line, acc ->
      line = line |> String.trim() |> String.trim_leading("﻿") |> String.trim()

      with false <- line == "" or String.starts_with?(line, "#"),
           [k, v] <- String.split(line, "=", parts: 2) do
        k = k |> String.trim() |> String.upcase()
        v = v |> String.trim() |> String.trim("\"") |> String.trim()
        Map.put_new(acc, k, v)
      else
        _ -> acc
      end
    end)
  end

  defp short(s), do: String.slice(s, 0, 20)

  defp parse_keys(out, seen) do
    s = seen |> Map.get("SCREEN", "hdmi") |> String.downcase()
    s = if s == "", do: "hdmi", else: Map.get(@aliases, s, s)
    t = seen |> Map.get("TOUCH", "auto") |> String.downcase()
    p = []

    {screen, p} =
      cond do
        s in @hdmi_words -> {"hdmi", p}
        Map.has_key?(@presets, s) and @presets[s].kind == :spi -> {s, p}
        true -> {"hdmi", p ++ ["SCREEN=#{short(s)} is not a choice; hdmi"]}
      end

    # MPI3508 means its touch, whatever TOUCH= says (it has no other reason to be in the file)
    mpi = String.downcase(Map.get(seen, "SCREEN", "")) == "mpi3508"

    {touch, p} =
      cond do
        screen != "hdmi" -> {if(@presets[screen].touch, do: "xpt2046", else: "off"), p}
        mpi or t in @touch_on -> {"xpt2046", p}
        t in @touch_off or t in ["auto", ""] -> {"off", p}
        true -> {"off", p ++ ["TOUCH=#{short(t)} is not a choice; off"]}
      end

    preset =
      cond do
        screen != "hdmi" -> screen
        touch == "xpt2046" -> "hdmi-xpt2046"
        true -> nil
      end

    r = Map.get(seen, "ROTATE", "0")

    {rotate, p} =
      if r in ~w(0 90 180 270),
        do: {String.to_integer(r), p},
        else: {0, p ++ ["ROTATE=#{short(r)} is not 0, 90, 180 or 270; 0"]}

    m = seen |> Map.get("MODE", @default_mode) |> String.downcase()
    m = if m == "", do: @default_mode, else: m

    {mode, p} =
      if m in @modes, do: {m, p}, else: {@default_mode, p ++ ["MODE=#{short(m)} is not a choice; #{@default_mode}"]}

    {manual, p} = manual(Map.get(seen, "CALIBRATION", ""), Map.get(seen, "SWAPXY", ""), preset, p)

    u = seen |> Map.get("UI", "auto") |> String.downcase()
    u = if u == "", do: "auto", else: u

    {ui, p} =
      if u in ~w(auto compact normal),
        do: {u, p},
        else: {"auto", p ++ ["UI=#{short(u)} is not auto, compact or normal; auto"]}

    %{
      out
      | screen: screen,
        preset: preset,
        touch: touch,
        rotate: rotate,
        mode: mode,
        manual: manual,
        ui: ui,
        problems: p
    }
  end

  defp manual("", _swap, _preset, p), do: {nil, p}

  defp manual(c, swap, preset, p) do
    default_swap =
      case preset && @presets[preset].cal do
        {_, _, _, _, s} -> s
        _ -> false
      end

    swap =
      case String.downcase(swap) do
        "" -> default_swap
        w -> w in ~w(1 yes ja on true)
      end

    nums = c |> String.replace(",", " ") |> String.split()

    v4 =
      Enum.map(nums, fn n ->
        case Integer.parse(n) do
          {i, ""} -> i
          _ -> nil
        end
      end)

    case v4 do
      [x0, x1, y0, y1] when is_integer(x0) and is_integer(x1) and is_integer(y0) and is_integer(y1) ->
        if Enum.all?(v4, &(&1 in 0..4095)) and abs(x1 - x0) >= 200 and abs(y1 - y0) >= 200,
          do: {{x0, x1, y0, y1, swap}, p},
          else: {nil, p ++ [cal_problem()]}

      _ ->
        {nil, p ++ [cal_problem()]}
    end
  end

  defp cal_problem, do: "CALIBRATION= needs four numbers 0-4095 (x min, x max, y min, y max); the defaults instead"

  # --------------------------------------------------------------------------------- the plan --

  @doc """
  What a boot does for a parsed file, given what the live device tree has: `%{overlays, modules, driver}`
  (empty lists for a plain HDMI screen). `tree`: `%{spi_pins: bool, spidev0: bool, spidev1: bool}`.
  The helpers come first; the last overlay is the one that switches SPI on.
  """
  def plan(%{preset: nil}, _tree), do: %{overlays: [], modules: [], driver: nil}

  def plan(%{preset: key, rotate: rot}, tree) do
    pr = @presets[key]
    spi = pr.kind == :spi

    own = if spi, do: "#{pr.overlay}-r#{panel_rotation(key, rot)}", else: pr.overlay

    overlays =
      Enum.reject(
        [
          if(spi and tree.spidev0, do: "alnasl-spidev0-off"),
          if(tree.spidev1, do: "alnasl-spidev1-off"),
          if(not tree.spi_pins, do: "alnasl-spi0-pins"),
          own
        ],
        &is_nil/1
      )

    %{overlays: overlays, modules: pr.modules, driver: pr.driver}
  end

  @doc """
  The screen's pages (v7.4): "compact" (the zero-touch QR and status page, AlnaslSetup.Compact) or "normal" (the
  menu and the role's own page). UI=compact and UI=normal decide; UI=auto means compact on a panel on the pins
  (480x320 and smaller do not hold the big pages) and normal on HDMI, the 3.5-inch HDMI stylus screen included.
  """
  def ui_mode(%{ui: "compact"}), do: "compact"
  def ui_mode(%{ui: "normal"}), do: "normal"
  def ui_mode(%{preset: key}) when is_binary(key), do: if(@presets[key].kind == :spi, do: "compact", else: "normal")
  def ui_mode(_), do: "normal"

  @doc "The kiosk shows the compact pages (what this boot decided; no state yet: normal). A panel that never came up
  leaves the picture on HDMI, and the big pages with it."
  def compact_ui? do
    st = read_state()
    st["ui"] == "compact" and st["status"] != "no_panel"
  end

  @doc "The driver's `rotation` for a preset and the file's ROTATE (both in degrees)."
  def panel_rotation(key, rot), do: rem(@presets[key].base + rot, 360)

  @doc "Every overlay the image must ship (verify.sh checks they are all there)."
  def all_overlays do
    spi =
      for {_k, %{kind: :spi, overlay: o}} <- @presets, r <- [0, 90, 180, 270], uniq: true, do: "#{o}-r#{r}"

    Enum.sort(["alnasl-spidev0-off", "alnasl-spidev1-off", "alnasl-spi0-pins", "alnasl-xpt2046" | spi])
  end

  # ---------------------------------------------------------------------------- the matrices --
  # An affine map of the unit square as {a, b, c, d, e, f}: x' = a x + b y + c, y' = d x + e y + f.
  # libinput's LIBINPUT_CALIBRATION_MATRIX is exactly these six numbers, on normalised device coordinates.

  def identity, do: {1.0, 0.0, 0.0, 0.0, 1.0, 0.0}

  @doc "A after B."
  def compose({a, b, c, d, e, f}, {p, q, r, s, t, u}) do
    {a * p + b * s, a * q + b * t, a * r + b * u + c, d * p + e * s, d * q + e * t, d * r + e * u + f}
  end

  def det({a, b, _c, d, e, _f}), do: a * e - b * d

  def invert({a, b, c, d, e, f} = m) do
    dd = det(m)
    if abs(dd) < 1.0e-9, do: raise(ArgumentError, "matrix cannot be inverted")
    ia = e / dd
    ib = -b / dd
    id = -d / dd
    ie = a / dd
    {ia, ib, -(ia * c + ib * f), id, ie, -(id * c + ie * f)}
  end

  def transform({a, b, c, d, e, f}, x, y), do: {a * x + b * y + c, d * x + e * y + f}

  @doc "The panel's own (ROTATE=0) coordinates -> the picture's, the picture turned `deg` clockwise."
  def rotation(0), do: identity()
  def rotation(90), do: {0.0, 1.0, 0.0, -1.0, 0.0, 1.0}
  def rotation(180), do: {-1.0, 0.0, 1.0, 0.0, -1.0, 1.0}
  def rotation(270), do: {0.0, -1.0, 1.0, 1.0, 0.0, 0.0}

  @doc """
  An evdev-style calibration (x min, x max, y min, y max, swap axes) as a matrix on normalised coordinates:
  what a vendor's 99-calibration.conf says, in libinput's terms.
  """
  def evdev_matrix({x0, x1, y0, y1, swap}) do
    sx = @range / (x1 - x0)
    sy = @range / (y1 - y0)
    ox = -x0 / (x1 - x0)
    oy = -y0 / (y1 - y0)
    if swap, do: {0.0, sx, ox, sy, 0.0, oy}, else: {sx, 0.0, ox, 0.0, sy, oy}
  end

  @doc """
  A calibration worth applying: six finite numbers, not degenerate, not absurd. Any panel of these types is
  within a factor of a few of the identity (or a swap or flip of it).
  """
  def sane?(m) when is_tuple(m), do: sane?(Tuple.to_list(m))

  def sane?(l) when is_list(l) and length(l) == 6 do
    Enum.all?(l, &(is_number(&1) and abs(&1) <= 8)) and
      abs(det(List.to_tuple(l))) |> then(&(&1 >= 0.1 and &1 <= 10))
  end

  def sane?(_), do: false

  # 3x3 linear system by Cramer's rule (it is three equations).
  defp solve3(a, y) do
    d3 = fn [[a1, a2, a3], [b1, b2, b3], [c1, c2, c3]] ->
      a1 * (b2 * c3 - b3 * c2) - a2 * (b1 * c3 - b3 * c1) + a3 * (b1 * c2 - b2 * c1)
    end

    d = d3.(a)
    if abs(d) < 1.0e-12, do: raise(ArgumentError, "the taps do not span the screen")

    for i <- 0..2 do
      m =
        a
        |> Enum.with_index()
        |> Enum.map(fn {row, j} -> List.replace_at(row, i, Enum.at(y, j)) end)

      d3.(m) / d
    end
  end

  @doc "Least-squares affine map from [{sx, sy, tx, ty}, ...]: source -> target."
  def fit(pairs) when length(pairs) >= 3 do
    zero = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]

    {ata, atx, aty} =
      Enum.reduce(pairs, {zero, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]}, fn {sx, sy, tx, ty}, {m, bx, by} ->
        row = [sx, sy, 1.0]

        m =
          for {r, i} <- Enum.with_index(m),
              do: for({v, j} <- Enum.with_index(r), do: v + Enum.at(row, i) * Enum.at(row, j))

        bx = for {v, i} <- Enum.with_index(bx), do: v + Enum.at(row, i) * tx
        by = for {v, i} <- Enum.with_index(by), do: v + Enum.at(row, i) * ty
        {m, bx, by}
      end)

    [a, b, c] = solve3(ata, atx)
    [d, e, f] = solve3(ata, aty)
    {a, b, c, d, e, f}
  end

  def fit(_), do: raise(ArgumentError, "at least three points")

  # a tap 5 % of the screen away from where the fit puts it is a tap on the wrong cross
  @max_residual 0.05

  @doc """
  samples: four `[tx, ty, ox, oy]` in the picture's normalised coordinates: where the cross was, where the
  stylus landed with the calibration `current` (the full matrix X is using). Returns `{c, residual}`: the
  new calibration in the panel's own frame (ROTATE=0), so a later ROTATE= keeps it. Raises ArgumentError
  with a reason a person can act on.
  """
  def calibrate(samples, current, rotate) do
    if not is_list(samples) or length(samples) != 4, do: raise(ArgumentError, "four taps are needed")

    pts =
      for s <- samples do
        if not is_list(s) or length(s) != 4 or not Enum.all?(s, &is_number/1),
          do: raise(ArgumentError, "a tap is four numbers")

        v = Enum.map(s, &(&1 * 1.0))
        if not Enum.all?(v, &(&1 >= -0.05 and &1 <= 1.05)), do: raise(ArgumentError, "a tap outside the screen")
        v
      end

    inv = invert(current)

    raw =
      for [tx, ty, ox, oy] <- pts do
        {rx, ry} = transform(inv, ox, oy)
        {rx, ry, tx, ty}
      end

    l = fit(raw)
    lineup = "the taps do not line up; try again and tap the centre of each cross"
    if not sane?(l), do: raise(ArgumentError, lineup)

    res =
      raw
      |> Enum.map(fn {rx, ry, tx, ty} ->
        {x, y} = transform(l, rx, ry)
        :math.sqrt((x - tx) * (x - tx) + (y - ty) * (y - ty))
      end)
      |> Enum.max()

    if res > @max_residual, do: raise(ArgumentError, lineup)
    {compose(invert(rotation(rotate)), l), res}
  end

  @doc "{calibration in the panel's frame, where it came from}: the on-screen one, the file's, the preset's."
  def effective(cfg, stored) do
    cond do
      stored != nil and sane?(stored) ->
        {List.to_tuple(Enum.map(Tuple.to_list(stored), &(&1 * 1.0))), "screen"}

      cfg.manual != nil and sane?(evdev_matrix(cfg.manual)) ->
        {evdev_matrix(cfg.manual), "file"}

      true ->
        {evdev_matrix(@presets[cfg.preset].cal), "default"}
    end
  end

  defp f6(v), do: :erlang.float_to_binary(v * 1.0 + 0.0, decimals: 6)

  def matrix_text(m), do: m |> Tuple.to_list() |> Enum.map_join(" ", &f6/1)

  def udev_rule(m) do
    "# Written by alnasl-small-screen (AlnaslSetup.SmallScreen) at boot and after a calibration.\n" <>
      "# It lives in /run: the next boot makes it again from alnasl-screen.txt and the saved calibration.\n" <>
      "# A touchscreen and nothing else: as a pointer or a touchpad libinput lets the stylus move the pointer\n" <>
      "# and never click (v7.4; the module also says INPUT_PROP_DIRECT now).\n" <>
      ~s(ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="#{@touch_name}", ) <>
      ~s(ENV{ID_INPUT}="1", ENV{ID_INPUT_TOUCHSCREEN}="1", ENV{ID_INPUT_TOUCHPAD}="", ENV{ID_INPUT_TABLET}="", ) <>
      ~s(ENV{ID_INPUT_MOUSE}="", ENV{ID_INPUT_JOYSTICK}="", ENV{LIBINPUT_CALIBRATION_MATRIX}="#{matrix_text(m)}"\n)
  end

  @doc """
  What alnasl-kiosk reads at every start. SPI: the card and fb X must use (empty when the panel did not come
  up: the kiosk stays on HDMI). HDMI with stylus: the forced mode and the rotation.
  """
  def kiosk_env(cfg, card \\ "", fb \\ "") do
    {mode, rot} =
      case cfg.preset && @presets[cfg.preset].kind do
        :hdmi_touch -> {if(cfg.mode == "auto", do: "", else: cfg.mode), @xrandr[cfg.rotate]}
        _ -> {"", "normal"}
      end

    ~s(KIOSK_CARD="#{card}"\nKIOSK_FB="#{fb}"\nKIOSK_FORCE_MODE="#{mode}"\nKIOSK_ROTATE="#{rot}"\n)
  end

  # ------------------------------------------------------------------------------------ the box --

  defp now, do: trunc(Sys.now())

  defp stored_for(preset) do
    with %{} = d <- Json.decode_or_nil(Sys.read(@cal_file, "")),
         ^preset <- d["screen"],
         m when is_list(m) <- d["matrix"],
         true <- sane?(m) do
      List.to_tuple(Enum.map(m, &(&1 * 1.0)))
    else
      _ -> nil
    end
  end

  defp save_stored(preset, c) do
    Sys.write_atomic(
      @cal_file,
      Json.encode(%{
        "screen" => preset,
        "matrix" => Enum.map(Tuple.to_list(c), &Float.round(&1 * 1.0, 6)),
        "at" => now()
      }) <> "\n",
      0o600
    )
  end

  @doc "The state of this boot (state.json), or what a box that has not run it looks like."
  def read_state do
    case Json.decode_or_nil(Sys.read(@state_file, "")) do
      %{} = st -> st
      _ -> %{"screen" => "hdmi", "touch" => "off", "status" => "not_started"}
    end
  end

  defp write_state(st), do: Sys.write_atomic(@state_file, Json.encode(st) <> "\n")

  defp dt_string(p), do: p |> Sys.read("") |> String.trim_trailing(<<0>>) |> String.trim()

  # /dev/input/eventN of the touch controller, or nil
  defp find_touch do
    case File.ls(Sys.path("/sys/class/input")) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.find_value(fn n ->
          if String.starts_with?(n, "event") and dt_string("/sys/class/input/#{n}/device/name") == @touch_name,
            do: "/dev/input/" <> n
        end)

      _ ->
        nil
    end
  end

  @doc "The DRM card (\"card1\") whose device the driver `drv` has bound, and its fb (\"fb1\"), or nils."
  def find_panel(drv) do
    root = String.replace(Sys.path("/sys/class/drm"), "\\", "/")

    card =
      (root <> "/card*")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.filter(&Regex.match?(~r/\Acard[0-9]+\z/, &1))
      |> Enum.sort()
      |> Enum.find(fn c ->
        case :file.read_link(String.to_charlist(Sys.path("/sys/class/drm/#{c}/device/driver"))) do
          {:ok, t} -> Path.basename(List.to_string(t)) == drv
          _ -> false
        end
      end)

    groot = String.replace(Sys.path("/sys/class/graphics"), "\\", "/")

    fb =
      (groot <> "/fb*")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()
      |> Enum.find(fn f -> dt_string("/sys/class/graphics/#{f}/name") == drv <> "drmfb" end)

    {card, fb}
  end

  defp apply_overlay(name) do
    d = @cfs <> "/" <> name

    if Sys.dir?(d) do
      st = dt_string(d <> "/status")
      {st == "applied", if(st == "", do: "?", else: st)}
    else
      with blob when is_binary(blob) <- Sys.read(@dtbo_dir <> "/" <> name <> ".dtbo", nil),
           :ok <- File.mkdir(Sys.path(d)),
           :ok <- File.write(Sys.path(d <> "/dtbo"), blob) do
        st = dt_string(d <> "/status")
        {st == "applied", if(st == "", do: "?", else: st)}
      else
        nil -> {false, "#{name}.dtbo is not in the image"}
        {:error, e} -> {false, "write failed: #{:file.format_error(e)}"}
      end
    end
  end

  defp tree do
    spi = dt_string(@dt <> "/__symbols__/spi")
    spi = if spi == "", do: @spi_node, else: spi

    %{
      spi_pins: Sys.exists?(@dt <> spi <> "/pinctrl-0"),
      spidev0: Sys.dir?(@dt <> @spi_node <> "/spidev@0"),
      spidev1: Sys.dir?(@dt <> @spi_node <> "/spidev@1")
    }
  end

  # The udev rule from the file's settings and the saved calibration; retriggers the device when it is there.
  defp rewrite_rule(cfg, st) do
    {c, src} = effective(cfg, stored_for(cfg.preset))
    m = compose(rotation(cfg.rotate), c)
    Sys.write_atomic(@rule, udev_rule(m))
    Sys.run(["udevadm", "control", "--reload"])
    dev = find_touch()

    if dev do
      Sys.run(["udevadm", "trigger", "--action=change", String.replace(dev, "/dev/input/", "/sys/class/input/")])
      Sys.run(["udevadm", "settle", "--timeout=5"])
    end

    round6 = fn t -> Enum.map(Tuple.to_list(t), &Float.round(&1 * 1.0, 6)) end
    Map.merge(st, %{"source" => src, "calibration" => round6.(c), "matrix" => round6.(m), "device" => dev})
  end

  # fun's answer once there? says it is there, or the last answer after `tries` more polls (250 ms apart).
  defp wait_for(fun, there?, tries) do
    r = fun.()

    if there?.(r) or tries <= 0 do
      r
    else
      Process.sleep(Application.get_env(:alnasl_setup, :small_screen_poll_ms, 250))
      wait_for(fun, there?, tries - 1)
    end
  end

  defp rm(p), do: File.rm(Sys.path(p))

  @doc "The boot run. Always 0: a screen is never a reason for a box not to start."
  def boot do
    File.mkdir_p(Sys.path(@run))
    data = Sys.read(@boot_file, nil)

    if data == nil and Sys.regular?(@template) and Sys.dir?(Path.dirname(@boot_file)) do
      # Somebody deleted it: the box puts the template back (SCREEN=hdmi), so the next person finds it.
      case File.read(Sys.path(@template)) do
        {:ok, t} ->
          Sys.write_atomic(@boot_file, t)
          log("alnasl-screen.txt was missing; the template is back on the boot partition (SCREEN=hdmi)")

        {:error, e} ->
          log("alnasl-screen.txt is missing and could not be re-created: #{:file.format_error(e)}")
      end
    end

    cfg = parse(data)
    for p <- cfg.problems, p != "no file", do: log("alnasl-screen.txt: " <> p)

    st = %{
      "screen" => cfg.screen,
      "touch" => cfg.touch,
      "rotate" => cfg.rotate,
      "mode" => cfg.mode,
      "ui" => ui_mode(cfg),
      "problems" => cfg.problems,
      "at" => now()
    }

    if cfg.preset == nil do
      rm(@rule)
      rm(@kiosk_env)
      write_state(Map.put(st, "status", "off"))
      log("SCREEN=hdmi: nothing on the pins; SPI stays off")
    else
      boot_on(cfg, st)
    end

    0
  end

  defp boot_on(cfg, st) do
    pr = @presets[cfg.preset]
    st = Map.put(st, "preset", cfg.preset)
    # the kiosk's first idea: HDMI, until the panel is really there
    Sys.write_atomic(@kiosk_env, kiosk_env(cfg))
    # before the device exists, so its first "add" already has the matrix
    st =
      if pr.touch,
        do: rewrite_rule(cfg, st),
        else:
          (
            rm(@rule)
            st
          )

    if not Sys.dir?(@cfs) and not Sys.dir?(@cfs_root <> "/device-tree"),
      do: Sys.run(["mount", "-t", "configfs", "configfs", @cfs_root])

    if not Sys.dir?(@cfs) do
      write_state(Map.put(st, "status", "no_overlay_support"))
      log("this kernel has no configfs device-tree overlays; the screen stays off")
    else
      p = plan(cfg, tree())

      failed =
        Enum.find_value(p.overlays, fn name ->
          {ok, word} = apply_overlay(name)
          log("overlay #{name}: #{word}")
          if not ok, do: name
        end)

      if failed do
        write_state(Map.merge(st, %{"status" => "overlay_failed", "overlay" => failed, "overlays" => p.overlays}))
      else
        for m <- p.modules do
          {rc, out} = Sys.run(["modprobe", m], stderr: :merge)
          if rc != 0, do: log("modprobe #{m}: #{String.slice(String.trim(out), -200, 200)}")
        end

        st = Map.put(st, "overlays", p.overlays)
        st = if pr.kind == :spi, do: panel_up(cfg, pr, st), else: st
        st = if pr.touch, do: touch_up(st), else: st

        status =
          cond do
            pr.kind == :spi and st["card"] == nil -> "no_panel"
            pr.touch and st["device"] == nil -> "no_touch"
            true -> "ready"
          end

        write_state(Map.put(st, "status", status))

        log(
          "#{cfg.preset}: #{status}; rotation #{cfg.rotate}" <>
            if(pr.kind == :spi, do: ", panel #{st["card"] || "missing"}/#{st["fb"] || "-"}", else: ", mode #{cfg.mode}") <>
            if(pr.touch, do: ", stylus #{st["device"] || "missing"} (calibration from #{st["source"]})", else: "")
        )
      end
    end
  end

  defp panel_up(cfg, pr, st) do
    case wait_for(fn -> find_panel(pr.driver) end, &match?({c, _} when c != nil, &1), 40) do
      {nil, _} ->
        log(
          "the overlays are in but no #{pr.driver} card appeared (panel not on the pins? see dmesg); the kiosk stays on HDMI"
        )

        st

      {card, fb} ->
        # The pipe on: the driver sends the panel its init sequence now, not when somebody first opens the card.
        if fb do
          case File.write(Sys.path("/sys/class/graphics/#{fb}/blank"), "0") do
            :ok -> :ok
            {:error, e} -> log("unblank #{fb}: #{:file.format_error(e)}")
          end
        end

        Sys.write_atomic(@kiosk_env, kiosk_env(cfg, card, if(fb, do: "/dev/" <> fb, else: "")))
        Map.merge(st, %{"card" => card, "fb" => fb, "size" => pr.size})
    end
  end

  defp touch_up(st) do
    case wait_for(&find_touch/0, &(&1 != nil), 40) do
      nil ->
        log("no #{@touch_name} appeared (the stylus will not work; see dmesg for ads7846)")
        st

      dev ->
        Sys.run(["udevadm", "settle", "--timeout=5"])
        Map.put(st, "device", dev)
    end
  end

  def status, do: Map.put(read_state(), "stored", stored_for(read_state()["preset"]) != nil)

  @doc "What Settings > Touch screen shows (GET /api/touch)."
  def touch_status do
    st = status()

    %{
      "screen" => st["screen"] || "hdmi",
      "touch" => st["touch"] || "off",
      "status" => st["status"] || "not_started",
      "rotate" => st["rotate"] || 0,
      "mode" => if(st["card"], do: st["size"], else: st["mode"]),
      "source" => st["source"],
      "device" => st["device"] != nil,
      "stored" => st["stored"],
      "problems" => st["problems"] || []
    }
  end

  @doc "The small screen fixes the picture (an SPI panel up, or MODE= on an HDMI stylus screen): Resolution stands aside."
  def forced? do
    st = read_state()

    cond do
      st["card"] != nil -> true
      st["preset"] == "hdmi-xpt2046" and st["mode"] not in [nil, "auto"] -> true
      true -> false
    end
  end

  # The file as it is now, with the rotation and preset X was started with (an edit since waits for the next boot).
  defp cfg_now(st) do
    cfg = parse(Sys.read(@boot_file, nil))
    %{cfg | rotate: st["rotate"] || 0, preset: st["preset"]}
  end

  @doc "The on-screen calibration: fit, save to the data partition, new rule. {c, residual}"
  def save_calibration(samples) do
    st = read_state()
    preset = st["preset"]

    if st["touch"] != "xpt2046" or preset == nil or not @presets[preset].touch,
      do: raise(ArgumentError, "the touch screen is off (alnasl-screen.txt)")

    current = st["matrix"]
    if not sane?(current), do: raise(ArgumentError, "no calibration in use to start from")
    current = List.to_tuple(Enum.map(current, &(&1 * 1.0)))
    {c, res} = calibrate(samples, current, st["rotate"] || 0)
    save_stored(preset, c)
    write_state(rewrite_rule(cfg_now(st), st))
    log("calibrated on screen (fit within #{:erlang.float_to_binary(res * 100, decimals: 1)} % of the screen); saved")
    {c, res}
  end

  def reset_calibration do
    rm(@cal_file)
    st = read_state()
    preset = st["preset"]

    if st["touch"] == "xpt2046" and preset != nil and @presets[preset].touch do
      write_state(rewrite_rule(cfg_now(st), st))
    end

    st = read_state()

    log(
      "on-screen calibration removed; back to #{if st["source"] == "file", do: "alnasl-screen.txt's", else: "the built-in"} values"
    )

    st
  end

  def main(["--status" | _]) do
    IO.puts(Json.encode(status()))
    0
  end

  def main(_args) do
    try do
      boot()
    rescue
      e ->
        log("failed: #{Exception.message(e)}; the screen stays as it is")
        0
    end
  end
end
