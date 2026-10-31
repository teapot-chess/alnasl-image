defmodule AlnaslSetup.Splash do
  @moduledoc """
  alnasl-splash: the boot screen, painted straight into the framebuffer (v6; the log is v7).

      alnasl-splash --hold              at boot: paint, and paint again whenever the framebuffer is
                                        replaced or cleared (vc4 taking over from the firmware's) or
                                        the state changes; stop once X (or cage) owns the screen
      alnasl-splash --once              paint once (after the kiosk stops, between its restarts)
      alnasl-splash --set STATE|clear   say what the box is doing (screens in messages.json), paint once
      alnasl-splash --next STATE|clear  the state to show at the next boot, until the kiosk is up
      alnasl-splash --value TEXT|clear  the value a state shows in its line's place ("37%", "v6.2"; system updates)
      alnasl-splash --progress N|clear  0-100, the bar a state shows in its step squares' place
      alnasl-splash --shutdown reboot|poweroff   the last picture before the power goes

  The pictures are made on the PC by scripts/render-splash.py: the same mark, colours and text
  the browser shows (/boot, /screen), so the hand-over from framebuffer to X to Chromium is a
  picture replaced by itself. No Plymouth (not in Photon's aarch64 repos), no decoder: the mark is
  seven rectangles and the text is pre-rendered coverage.

  v7: while the box starts ("boot", and under the first boot's steps), the screen also shows a status line
  ("starting nunki - 7 of 12 up") and the box's log scrolling below the mark, newest at the bottom, older
  lines fading, coloured by where they came from. What may be shown, and the redaction of everything that
  looks like a secret, is `AlnaslSetup.Bootlog`'s (the setup server's /api/bootlog serves the same lines to
  the browser's /boot page, which carries on from here once X has the screen). Text comes from a monospace
  glyph atlas of printable ASCII; only the rows of the log are rewritten when it moves. The update and reset
  screens are v6's, unchanged.

  It never paints while X or cage runs, and never over a text console someone is using (only
  when tty1 is the active VT). Painting puts tty1 in graphics mode so the console stops drawing
  over the picture; X takes the VT over from there and gives it back in text mode when it ends.

  Elixir cannot ioctl, so the two ioctls (FBIOGET_VSCREENINFO, KDSETMODE) are done by a small C helper,
  `/opt/alnasl-setup/bin/alnasl-fbtool` (setup-app/c_src/alnasl-fbtool.c). The pixels go to /dev/fb0 as an
  ordinary positioned write.
  """

  alias AlnaslSetup.{Bootlog, Json, Sys}
  alias AlnaslSetup.Bootlog.Follower
  import Bitwise

  @share "/usr/share/alnasl/splash"
  @run_dir "/run/alnasl-screen"
  @run_state @run_dir <> "/state"
  @run_value @run_dir <> "/value"
  @run_progress @run_dir <> "/progress"
  @value_chars ~c"0123456789.v%"
  @next_boot "/var/lib/alnasl-screen/next-boot"
  @lang_file "/var/lib/alnasl-setup/state.json"
  @fb "/dev/fb0"
  @fb_sys "/sys/class/graphics/fb0"
  @tty1 "/dev/tty1"
  @fbtool "/opt/alnasl-setup/bin/alnasl-fbtool"

  @bg {0x16, 0x17, 0x1A}
  @ink {0xE9, 0xE9, 0xE6}
  @accent {0xE2, 0xA0, 0x8C}
  @dim {0xA3, 0xA3, 0x9F}
  @outline {0x55, 0x56, 0x5A}
  @mark [{0, 0, :ink}, {1, 0, :ink}, {2, 0, :accent}, {1, 1, :ink}, {2, 1, :ink}, {0, 2, :ink}, {2, 2, :ink}]

  # v7: the states that show the box's log. "boot" and "waiting": the log instead of a title; the first
  # boot's steps: under them. Everything else (updates, reset, shutdown) is v6's picture alone.
  @log_states ["boot", "waiting", "firstboot-1", "firstboot-2", "firstboot-3"]
  @log_keep 200
  @log_fps 5

  @usage """
  usage: alnasl-splash --hold | --once | --set STATE|clear | --next STATE|clear
                       | --value TEXT|clear | --progress N|clear | --shutdown reboot|poweroff
  """

  def accent, do: @accent
  def bg, do: @bg
  def ink, do: @ink
  def log_states, do: @log_states

  defp log(msg), do: Sys.log("alnasl-splash", msg)

  # Python's read(): the text of a file, stripped, or the default.
  defp read(p, default \\ "") do
    case File.read(Sys.path(p)) do
      {:ok, data} -> String.trim(data)
      {:error, _} -> default
    end
  end

  @doc "messages.json: geometry, states, glyph advances, the log layout."
  def messages do
    with data when is_binary(data) <- Sys.read(@share <> "/messages.json", nil),
         {:ok, %{} = m} <- Json.decode(data) do
      m
    else
      _ -> %{"geometry" => %{}, "states" => %{}}
    end
  end

  defp states(msg), do: Map.get(msg, "states") || %{}

  defp lang do
    case Json.decode(Sys.read(@lang_file, "")) do
      {:ok, %{"lang" => "nl"}} -> "nl"
      _ -> "en"
    end
  end

  defp state(msg) do
    s =
      case read(@run_state) do
        "" -> read(@next_boot)
        s -> s
      end

    if Map.has_key?(states(msg), s), do: s, else: "boot"
  end

  defp value do
    v = read(@run_value)
    if v != "" and String.length(v) <= 12 and value_ok?(v), do: v, else: ""
  end

  defp value_ok?(v), do: v |> String.to_charlist() |> Enum.all?(&(&1 in @value_chars))

  defp progress do
    p = read(@run_progress)
    if p =~ ~r/\A[0-9]+\z/, do: p |> String.to_integer() |> min(100) |> max(0), else: nil
  end

  defp x_running? do
    case File.ls(Sys.path("/proc")) do
      {:ok, pids} ->
        Enum.any?(pids, fn pid -> pid =~ ~r/\A[0-9]+\z/ and read("/proc/#{pid}/comm") in ["Xorg", "cage"] end)

      _ ->
        false
    end
  end

  defp tty1_active?, do: read("/sys/class/tty/tty0/active", "tty1") == "tty1"

  # What /dev/fb0 is right now, to notice it being replaced. (Python's also had st_rdev; it is a constant of
  # the kernel's fb driver, and Elixir's file info does not carry it. The name and size say the rest.)
  defp fb_identity do
    case File.stat(Sys.path(@fb)) do
      {:ok, st} -> {st.inode, read(@fb_sys <> "/name"), read(@fb_sys <> "/virtual_size"), read(@fb_sys <> "/stride")}
      _ -> nil
    end
  end

  # ------------------------------------------------------------ numbers, pixels --
  # Python's round(): halves go to the even neighbour (the offsets here are floats times a scale).
  defp pyround(x) when is_integer(x), do: x

  defp pyround(x) do
    f = Float.floor(x)
    fi = trunc(f)
    d = x - f

    cond do
      d < 0.5 -> fi
      d > 0.5 -> fi + 1
      rem(fi, 2) == 0 -> fi
      true -> fi + 1
    end
  end

  defp fdiv(a, b), do: Integer.floor_div(a, b)

  defp blend({r1, g1, b1}, {r2, g2, b2}, t) do
    {pyround(r1 + (r2 - r1) * t / 255), pyround(g1 + (g2 - g1) * t / 255), pyround(b1 + (b2 - b1) * t / 255)}
  end

  defp rgb({_, _, _} = c), do: c
  defp rgb([r, g, b]), do: {r, g, b}

  @doc "A pixel of the framebuffer's own packing, as bytes."
  def px(fb, {r, g, b}) do
    [{ro, rn}, {go, gn}, {bo, bn}] = fb.chan
    v = (r >>> (8 - rn)) <<< ro ||| (g >>> (8 - gn)) <<< go ||| (b >>> (8 - bn)) <<< bo
    bits = fb.b * 8
    <<v::little-size(bits)>>
  end

  # A framebuffer as the painter sees it: size, stride, and how a pixel is packed. `pad` is the stride's
  # bytes beyond a row of pixels.
  @doc false
  def new_fb(w, h, bpp, pad \\ 0) do
    b = div(bpp, 8)
    chan = if b == 2, do: [{11, 5}, {5, 6}, {0, 5}], else: [{16, 8}, {8, 8}, {0, 8}]
    %{w: w, h: h, bpp: bpp, yoff: 0, b: b, chan: chan, stride: w * b + pad}
  end

  # Read /dev/fb0's geometry through the helper (the ioctl) and the stride through sysfs.
  defp open_fb do
    path = Sys.path(@fb)

    if not File.exists?(path) do
      {:error, "[Errno 2] No such file or directory: '#{@fb}'"}
    else
      case Sys.run([@fbtool, "vinfo", path]) do
        {0, out} -> fb_from_vinfo(parse_vinfo(out))
        {rc, _} -> {:error, "FBIOGET_VSCREENINFO failed (alnasl-fbtool exit #{rc})"}
      end
    end
  end

  defp parse_vinfo(out) do
    for line <- String.split(out, "\n"), [k, v] <- [String.split(line, "=", parts: 2)], into: %{} do
      case Integer.parse(String.trim(v)) do
        {n, _} -> {k, n}
        :error -> {k, 0}
      end
    end
  end

  defp fb_from_vinfo(v) do
    g = fn k -> Map.get(v, k, 0) end
    w = g.("xres")
    h = g.("yres")
    bpp = g.("bits_per_pixel")
    b = div(bpp, 8)

    if b not in [2, 3, 4] or w == 0 or h == 0 do
      {:error, "unsupported framebuffer: #{w}x#{h}, #{bpp} bpp"}
    else
      chan = [
        {g.("red_offset"), g.("red_length")},
        {g.("green_offset"), g.("green_length")},
        {g.("blue_offset"), g.("blue_length")}
      ]

      # a driver that leaves the layout empty: the usual ones
      chan =
        cond do
          Enum.any?(chan, fn {_, n} -> n != 0 end) -> chan
          b == 2 -> [{11, 5}, {5, 6}, {0, 5}]
          true -> [{16, 8}, {8, 8}, {0, 8}]
        end

      st = read(@fb_sys <> "/stride")

      stride =
        if st =~ ~r/\A[0-9]+\z/ and String.to_integer(st) >= w * b, do: String.to_integer(st), else: w * b

      {:ok, %{w: w, h: h, bpp: bpp, yoff: g.("yoffset"), b: b, chan: chan, stride: stride}}
    end
  end

  # A PGM (P5) picture: {width, height, coverage bytes}, or nil.
  defp pgm(path) do
    with data when is_binary(data) <- Sys.read(path, nil),
         [magic, dims, _max, pixels] <- String.split(data, "\n", parts: 4),
         true <- magic == "P5",
         [w, h] <- dims |> String.split() |> Enum.map(&String.to_integer/1),
         true <- byte_size(pixels) >= w * h do
      {w, h, binary_part(pixels, 0, w * h)}
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # [{coverage, advance}] for a value line, from the pre-rendered glyphs; nil if one is missing.
  defp glyph_run(msg, text, size) do
    meta = get_in(msg, ["glyphs", Integer.to_string(size)]) || %{}
    adv = meta["advance"] || %{}
    names = meta["names"] || %{}

    text
    |> String.graphemes()
    |> Enum.reduce_while([], fn ch, acc ->
      img = pgm("#{@share}/text/glyphs/#{size}/#{Map.get(names, ch, "?")}.pgm")

      if img == nil or not Map.has_key?(adv, ch),
        do: {:halt, nil},
        else: {:cont, [{img, adv[ch]} | acc]}
    end)
    |> case do
      nil -> nil
      acc -> Enum.reverse(acc)
    end
  end

  # ------------------------------------------------------------------ the frame --
  # The frame is built as a map of row => bytes (a row is `stride` bytes), so that painting a rectangle
  # copies the rows it touches and nothing else.
  defp new_ctx(fb) do
    blank = :binary.copy(px(fb, @bg), fb.w) <> :binary.copy(<<0>>, fb.stride - fb.w * fb.b)
    %{fb: fb, rows: %{}, blank: blank}
  end

  defp splice(%{rows: rows, blank: blank} = ctx, y, xbyte, bin) do
    row = Map.get(rows, y, blank)
    tail = xbyte + byte_size(bin)
    new = binary_part(row, 0, xbyte) <> bin <> binary_part(row, tail, byte_size(row) - tail)
    %{ctx | rows: Map.put(rows, y, new)}
  end

  defp rect(%{fb: fb} = ctx, x0, y0, w, h, colour) do
    x0 = max(0, x0)
    y0 = max(0, y0)
    w = min(w, fb.w - x0)
    h = min(h, fb.h - y0)

    if w <= 0 or h <= 0 do
      ctx
    else
      line = :binary.copy(px(fb, colour), w)
      Enum.reduce(y0..(y0 + h - 1)//1, ctx, fn y, c -> splice(c, y, x0 * fb.b, line) end)
    end
  end

  defp lut(fb, colour), do: List.to_tuple(for c <- 0..255, do: px(fb, blend(@bg, colour, c)))

  defp blit(%{fb: fb} = ctx, {w, h, cov}, x0, y0, colour) do
    if x0 < 0 or y0 < 0 or x0 + w > fb.w or y0 + h > fb.h do
      ctx
    else
      lut = lut(fb, colour)

      Enum.reduce(0..(h - 1)//1, ctx, fn r, c ->
        row = for <<v <- binary_part(cov, r * w, w)>>, into: <<>>, do: elem(lut, v)
        splice(c, y0 + r, x0 * fb.b, row)
      end)
    end
  end

  defp frame(%{fb: fb, rows: rows, blank: blank}) do
    for y <- 0..(fb.h - 1), into: <<>>, do: Map.get(rows, y, blank)
  end

  defp gget(g, k, default), do: Map.get(g, k) || default

  @doc """
  The whole picture as bytes (rows of `fb.stride` bytes) and the offset of a probe pixel in the middle of the
  accent square. Options: `:val` / `:prog` - the value line and the progress bar of the states that have
  them (default: what the update scripts left in /run); `:logv` - `{status line, lines}` of the v7 log, on
  the states that show it; `:msg` - messages.json.
  """
  def compose(fb, key, lng, opts \\ []) do
    msg = Keyword.get_lazy(opts, :msg, &messages/0)
    val = opts[:val]
    prog = opts[:prog]
    logv = opts[:logv]
    {w, h, stride} = {fb.w, fb.h, fb.stride}
    s = h / 1080
    cx = div(w, 2)
    cy = div(h, 2)
    ctx = new_ctx(fb)

    sq = pyround(90 * s)

    ctx =
      Enum.reduce(@mark, ctx, fn {col, row, colour}, c ->
        rect(c, cx + pyround((col * 105 - 150) * s), cy + pyround((row * 105 - 150) * s), sq, sq, mark_colour(colour))
      end)

    st = Map.get(states(msg), key) || %{}
    # the log says what is going on, not a title
    st = if logv != nil and key in ["boot", "waiting"], do: %{}, else: st

    ctx =
      if st["text"] do
        geo = Map.get(msg, "geometry") || %{}
        # text made for 1080 or 720 lines; offsets follow the real height
        size = if h < 900, do: 720, else: 1080
        base = "#{@share}/text/#{lng}/#{key}.#{size}"

        ctx =
          Enum.reduce([{"title", gget(geo, "title_y", 214), @ink}, {"sub", gget(geo, "sub_y", 282), @dim}], ctx, fn
            {line, top, colour}, c ->
              case pgm(base <> "." <> line <> ".pgm") do
                nil -> c
                {iw, _, _} = img -> blit(c, img, cx - div(iw, 2), cy + pyround(top * s), colour)
              end
          end)

        ctx = if st["value"], do: value_line(ctx, msg, geo, size, s, cx, cy, val), else: ctx
        ctx = if st["bar"], do: bar(ctx, st, geo, s, cx, cy, prog), else: ctx

        case st["steps"] do
          [done, total] -> steps(ctx, geo, s, cx, cy, done, total)
          _ -> ctx
        end
      else
        ctx
      end

    ctx =
      case logv do
        nil -> ctx
        {status, lines} -> put_log(ctx, log_region(fb, key, status, lines, msg), stride)
      end

    {frame(ctx), (cy - pyround(105 * s)) * stride + (cx + pyround(105 * s)) * fb.b}
  end

  defp mark_colour(:ink), do: @ink
  defp mark_colour(:accent), do: @accent

  defp put_log(ctx, nil, _), do: ctx

  defp put_log(ctx, {y0, data}, stride) do
    rows = for {row, i} <- Enum.with_index(chunk(data, stride)), into: ctx.rows, do: {y0 + i, row}
    %{ctx | rows: rows}
  end

  defp chunk(<<>>, _), do: []
  defp chunk(data, n), do: [binary_part(data, 0, n) | chunk(binary_part(data, n, byte_size(data) - n), n)]

  defp value_line(ctx, msg, geo, size, s, cx, cy, val) do
    case glyph_run(msg, if(val == nil, do: value(), else: val), size) do
      nil ->
        ctx

      run ->
        # the glyphs are made for `size` lines; offsets follow the real height
        gs = s * 1080 / size
        width = pyround(Enum.sum(for {_, a} <- run, do: a) * gs)
        y = cy + pyround(gget(geo, "sub_y", 282) * s)

        {ctx, _} =
          Enum.reduce(run, {ctx, cx - fdiv(width, 2)}, fn {img, a}, {c, x} ->
            {blit(c, img, x, y, @ink), x + pyround(a * gs)}
          end)

        ctx
    end
  end

  defp bar(ctx, st, geo, s, cx, cy, prog) do
    p = if prog == nil, do: progress(), else: prog
    bw = pyround(gget(geo, "bar_w", 360) * s)
    bh = max(2, pyround(gget(geo, "bar_h", 6) * s))
    # squares too: under them
    under = if st["steps"], do: gget(geo, "bar_steps_y", 380), else: gget(geo, "dots_y", 346)
    bx = cx - fdiv(bw, 2)
    by = cy + pyround(under * s)
    ctx = rect(ctx, bx, by, bw, bh, @outline)
    if p != nil and p != 0, do: rect(ctx, bx, by, pyround(bw * p / 100), bh, @accent), else: ctx
  end

  defp steps(ctx, geo, s, cx, cy, done, total) do
    dot = pyround(gget(geo, "dot", 14) * s)
    gap = pyround(gget(geo, "dot_gap", 10) * s)
    x0 = cx - fdiv(total * dot + (total - 1) * gap, 2)
    y = cy + pyround(gget(geo, "dots_y", 346) * s)
    lw = max(1, pyround(2 * s))

    {ctx, _} =
      Enum.reduce(1..total//1, {ctx, x0}, fn i, {c, x} ->
        c =
          if i <= done do
            rect(c, x, y, dot, dot, if(i == done, do: @accent, else: @ink))
          else
            c
            |> rect(x, y, dot, lw, @outline)
            |> rect(x, y + dot - lw, dot, lw, @outline)
            |> rect(x, y, lw, dot, @outline)
            |> rect(x + dot - lw, y, lw, dot, @outline)
          end

        {c, x + dot + gap}
      end)

    ctx
  end

  # ------------------------------------------------------------------ the log (v7) --
  # Where the status line and the log go. The /boot page (screen.html) computes the same from the same
  # numbers in messages.json, in its canvas's pixels, so the hand-over puts every line where it was.
  defp log_geom(w, h, key, msg) do
    mono = Map.get(msg, "mono") || %{}
    lv = Map.get(msg, "logview") || %{}
    size = if h < 900, do: 720, else: 1080
    m = Map.get(mono, Integer.to_string(size))

    if m == nil or m == %{} or lv == %{} do
      nil
    else
      s = h / 1080
      cx = div(w, 2)
      cy = div(h, 2)
      steps = (Map.get(states(msg), key) || %{})["steps"]
      steps? = steps not in [nil, false, []]
      a = m["adv"]
      lh = m["lh"]
      top = cy + pyround(if(steps?, do: lv["log_y_steps"], else: lv["log_y"]) * s)
      status_y = if steps?, do: nil, else: cy + pyround(lv["status_y"] * s)
      n = max(0, fdiv(h - pyround(lv["bottom"] * s) - top, lh))
      cols = max(10, min(lv["max_chars"], fdiv(w - 2 * pyround(lv["margin"] * s), a)))

      %{
        size: size,
        a: a,
        lh: lh,
        top: top,
        status_y: status_y,
        n: n,
        cols: cols,
        x0: cx - fdiv(cols * a, 2),
        cx: cx,
        y0: status_y || top,
        y1: top + n * lh,
        fade: lv["fade"],
        colours: lv["colours"]
      }
    end
  end

  # The glyph atlas as framebuffer bytes: for a colour and a fade level, every glyph's rows, ready to
  # join. Made the first time a colour is used (tens of ms each on a Pi 4) and kept in the process.
  defp atlas(fb, size, msg) do
    key = {:alnasl_splash_atlas, fb.w, fb.h, fb.b, fb.chan, size}

    case Process.get(key) do
      nil ->
        case pgm("#{@share}/text/mono/#{size}.pgm") do
          nil ->
            nil

          {w, h, cov} ->
            meta = msg["mono"][Integer.to_string(size)]
            # one atlas at a time, like Python's ATLASES.clear()
            for {{:alnasl_splash_atlas, _, _, _, _, _} = k, _} <- Process.get(), do: Process.delete(k)
            for {{:alnasl_splash_glyphs, _} = k, _} <- Process.get(), do: Process.delete(k)
            at = %{key: key, w: w, h: h, cov: cov, a: meta["adv"], first: meta["first"], count: meta["count"], fb: fb}
            Process.put(key, at)
            at
        end

      at ->
        at
    end
  end

  defp glyphs(at, colour, alpha) do
    k = {:alnasl_splash_glyphs, {at.key, colour, alpha}}

    case Process.get(k) do
      nil ->
        target = blend(@bg, colour, alpha)
        lut = lut(at.fb, target)
        {a, w, cov} = {at.a, at.w, at.cov}

        g =
          for i <- 0..(at.count - 1) do
            for r <- 0..(at.h - 1) do
              for <<v <- binary_part(cov, r * w + i * a, a)>>, into: <<>>, do: elem(lut, v)
            end
            |> List.to_tuple()
          end
          |> List.to_tuple()

        Process.put(k, g)
        g

      g ->
        g
    end
  end

  @doc """
  `{first row, bytes of rows y0..y1 as whole rows of fb.stride}` holding the status line and the log, or nil.
  """
  def log_region(fb, key, status, lines, msg \\ nil) do
    msg = msg || messages()
    {w, h, b, s} = {fb.w, fb.h, fb.b, fb.stride}
    g = log_geom(w, h, key, msg)

    with true <- g != nil and g.y1 > g.y0,
         %{} = at <- atlas(fb, g.size, msg) do
      bgp = px(fb, @bg)
      pad = :binary.copy(<<0>>, s - w * b)
      blank = :binary.copy(bgp, w) <> pad
      cols = g.colours

      colour = fn name, default ->
        case Map.get(cols, name) do
          nil -> default
          c -> rgb(c)
        end
      end

      put = fn rows, y, x, text, col, alpha ->
        text = String.slice(text, 0, max(0, fdiv(w - x, at.a)))
        gl = glyphs(at, col, alpha)

        idx =
          for <<c::utf8 <- text>>, do: (c - at.first) |> max(0) |> min(at.count - 1)

        left = :binary.copy(bgp, max(x, 0))
        right = :binary.copy(bgp, max(w - x - length(idx) * at.a, 0))

        Enum.reduce(0..(at.h - 1), rows, fn r, rows ->
          ry = y - g.y0 + r

          if ry >= 0 and ry < g.y1 - g.y0 do
            body = for i <- idx, into: <<>>, do: elem(elem(gl, i), r)
            Map.put(rows, ry, left <> body <> right <> pad)
          else
            rows
          end
        end)
      end

      rows =
        if g.status_y != nil and status != nil and status != "" do
          t = String.slice(status, 0, g.cols)
          put.(%{}, g.status_y, g.cx - fdiv(String.length(t) * at.a, 2), t, colour.("status", @ink), 255)
        else
          %{}
        end

      shown = if g.n > 0, do: Enum.take(lines, -g.n), else: []
      fade = g.fade
      total = length(shown)

      rows =
        shown
        |> Enum.with_index()
        |> Enum.reduce(rows, fn {{tag, col, err, text}, i}, rows ->
          age = total - 1 - i
          alpha = if err, do: 255, else: Enum.at(fade, min(age, length(fade) - 1))
          line = Bootlog.format_line(tag, text)
          put.(rows, g.top + i * at.h, g.x0, String.slice(line, 0, g.cols), colour.(col, @ink), alpha)
        end)

      {g.y0, for(i <- 0..(g.y1 - g.y0 - 1)//1, into: <<>>, do: Map.get(rows, i, blank))}
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------------------ painting --
  # tty1 in graphics mode: the console stops drawing (and clearing) on top of the picture.
  defp graphics_mode, do: Sys.run([@fbtool, "graphics", Sys.path(@tty1)])

  defp with_fb(fun) do
    path = Sys.path(@fb)

    case :file.open(path, [:read, :write, :raw, :binary]) do
      {:ok, fd} ->
        try do
          fun.(fd)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns {offset, bytes} of a probe pixel to check later, or nil when nothing was painted.
  defp paint(msg, key \\ nil, logv \\ nil) do
    if x_running?() or not tty1_active?() do
      nil
    else
      key = key || state(msg)

      case open_fb() do
        {:error, e} ->
          log("no framebuffer to paint on (#{e})")
          nil

        {:ok, fb} ->
          Process.put(:alnasl_splash_fb, {fb_identity(), fb})
          {frame, probe} = compose(fb, key, lang(), logv: logv, msg: msg)
          graphics_mode()
          base = fb.yoff * fb.stride

          case with_fb(fn fd -> :file.pwrite(fd, base, frame) end) do
            :ok ->
              {probe + base, px(fb, @accent)}

            {:error, e} ->
              log("painting failed: #{:file.format_error(e)}")
              nil
          end
      end
    end
  end

  defp intact?({off, bytes}) do
    case :file.open(Sys.path(@fb), [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          :file.pread(fd, off, byte_size(bytes)) == {:ok, bytes}
        after
          :file.close(fd)
        end

      _ ->
        false
    end
  end

  # The geometry of the framebuffer for the next log repaint: asked again only when the framebuffer looks
  # different (a repaint of the log is five a second; the helper is a process).
  defp cached_fb do
    ident = fb_identity()

    case Process.get(:alnasl_splash_fb) do
      {^ident, fb} when ident != nil ->
        {:ok, fb}

      _ ->
        with {:ok, fb} <- open_fb() do
          Process.put(:alnasl_splash_fb, {ident, fb})
          {:ok, fb}
        end
    end
  end

  # Only the rows of the status line and the log: the rest of the picture stays as it is.
  defp paint_log(msg, key, {status, lines}) do
    if x_running?() or not tty1_active?() do
      false
    else
      case cached_fb() do
        {:error, _} ->
          false

        {:ok, fb} ->
          case log_region(fb, key, status, lines, msg) do
            nil ->
              true

            {y0, data} ->
              case with_fb(fn fd -> :file.pwrite(fd, (fb.yoff + y0) * fb.stride, data) end) do
                :ok ->
                  true

                {:error, e} ->
                  log("painting the log failed: #{:file.format_error(e)}")
                  false
              end
          end
      end
    end
  end

  # ---------------------------------------------------------------------- hold --
  defp mono_ms, do: System.monotonic_time(:millisecond)

  defp hold(msg) do
    t0 = mono_ms()
    cmd = Application.get_env(:alnasl_setup, :journal_cmd) || Bootlog.journalctl_argv()

    loop(msg, t0, %{
      last: nil,
      probe: nil,
      follower: Follower.new(&Bootlog.role/0, cmd),
      lines: [],
      status: "",
      next_status: 0,
      dirty: false,
      last_log: 0
    })
  end

  defp loop(msg, t0, h) do
    if x_running?() do
      # X has the screen; the "after the update" picture of the next boot has done its job.
      File.rm(Sys.path(@next_boot))
      if h.follower, do: Follower.close(h.follower)

      log(
        "X is up after #{:erlang.float_to_binary((mono_ms() - t0) / 1000, decimals: 1)} s; the screen is its from here"
      )

      0
    else
      key = state(msg)
      {h, logv} = follow(h, key)
      sig = {key, lang(), fb_identity(), tty1_active?(), value(), progress()}

      h =
        cond do
          sig != h.last or (h.probe != nil and not intact?(h.probe)) ->
            %{h | probe: paint(msg, key, logv), last: sig, dirty: false, last_log: mono_ms()}

          logv != nil and h.dirty and mono_ms() - h.last_log >= 1000 / @log_fps ->
            paint_log(msg, key, logv)
            %{h | dirty: false, last_log: mono_ms()}

          true ->
            h
        end

      Process.sleep(if logv != nil or mono_ms() - t0 < 90_000, do: 100, else: 500)
      loop(msg, t0, h)
    end
  end

  # Poll the journal and the status line when this state shows them; returns the hold state and the
  # `{status, lines}` to paint (nil on states without the log).
  defp follow(%{follower: nil} = h, _key), do: {h, nil}

  defp follow(h, key) do
    if key in @log_states do
      h =
        try do
          {new, f} = Follower.poll(h.follower, 0)
          h = %{h | follower: f}
          h = if new != [], do: %{h | lines: Enum.take(h.lines ++ new, -@log_keep), dirty: true}, else: h
          now = mono_ms()

          if now >= h.next_status do
            st = if key in ["boot", "waiting"], do: Bootlog.status(lang())["text"], else: ""
            h = %{h | next_status: now + 1000}
            if st != h.status, do: %{h | status: st, dirty: true}, else: h
          else
            h
          end
        rescue
          e ->
            # the log is a nicety; the picture is not
            log("the log stopped: #{inspect(e)}")
            Follower.close(h.follower)
            %{h | follower: nil}
        end

      {h, {h.status, h.lines}}
    else
      {h, nil}
    end
  end

  # --------------------------------------------------------------- state files --
  # --value / --progress: a small file in /run the painter and the browser page read.
  defp set_plain(path, text) do
    real = Sys.path(path)

    if text == "clear" do
      File.rm(real)
    else
      File.mkdir_p!(Path.dirname(real))
      File.write!(real <> ".tmp", text <> "\n")
      File.rename!(real <> ".tmp", real)
    end

    true
  end

  defp set_state(path, key, msg) do
    real = Sys.path(path)

    cond do
      key == "clear" ->
        File.rm(real)
        true

      not Map.has_key?(states(msg), key) ->
        log("unknown state '#{key}'")
        false

      true ->
        File.mkdir_p!(Path.dirname(real))
        File.write!(real <> ".tmp", key <> "\n")
        File.rename!(real <> ".tmp", real)
        true
    end
  end

  @doc "The program: `argv` is the flags only. Returns the exit code."
  def main(argv) do
    msg = messages()

    case argv do
      ["--hold" | _] ->
        hold(msg)

      ["--once" | _] ->
        paint(msg)
        0

      ["--set", key] ->
        if set_state(@run_state, key, msg) do
          paint(msg)
          0
        else
          2
        end

      ["--value", v] ->
        if v != "clear" and not (String.length(v) <= 12 and value_ok?(v)) do
          log("a value is made of #{List.to_string(@value_chars)} only")
          2
        else
          set_plain(@run_value, v)
          paint(msg)
          0
        end

      ["--progress", v] ->
        if v != "clear" and not (v =~ ~r/\A[0-9]+\z/ and String.to_integer(v) <= 100) do
          log("progress is 0-100")
          2
        else
          set_plain(@run_progress, v)
          paint(msg)
          0
        end

      ["--next", key] ->
        if set_state(@next_boot, key, msg), do: 0, else: 2

      ["--shutdown", why] when why in ["reboot", "poweroff"] ->
        # A reset or an update already said why; otherwise just what is happening.
        cur = read(@run_state)

        paint(
          msg,
          if(Map.has_key?(states(msg), cur) and cur != "waiting",
            do: cur,
            else: if(why == "reboot", do: "reboot", else: "shutdown")
          )
        )

        0

      _ ->
        IO.write(:stderr, @usage)
        2
    end
  end
end
