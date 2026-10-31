# Renders the v6 boot screen and every screen that follows it (port of render-splash.py, no Python).
#
#   elixir scripts/render-splash.exs path/to/alnasl-src.tar [fonts/DejaVuSansMono.ttf] [options]
#
#   --out DIR       where to write (default: overlay/usr/share/alnasl/splash, like the Python did; point it
#                   somewhere else to try the renderer without touching the committed pictures)
#   --nunito FILE   take Nunito from this font file instead of the tar (see "Fonts" below)
#   --compare DIR   after writing, compare the result with DIR (the committed splash directory): file list,
#                   picture sizes, and messages.json value by value. Prints the differences, exits 1 if any.
#
# One look for every state the screen can be in: the Alnasl mark (brand/marks/alnasl.svg, nine squares on a
# 24 x 24 grid, drawn here as rectangles so nothing is lost to an SVG renderer) on Alnasl's dark theme
# background, and below it, when there is something to say, a title, a line and a row of step squares. The
# mark never moves from one screen to the next. Writes (same names, formats and sizes as the Python):
#   alnasl-splash.png                 1920x1080, the mark only (grub, the browser's first page)
#   messages.json                     the states, their steps and texts (alnasl-splash and server.py read it)
#   screens/<lang>/<state>.png        1920x1080, the full screen of each state (the browser shows these)
#   text/<lang>/<state>.<h>.title.pgm / .sub.pgm   the title and line as 8-bit coverage, h = 1080 and 720
#   text/glyphs/<h>/<name>.pgm        the few characters a changing value is made of: 0-9, dot, v, pct
#   screens/glyphs/<name>.png         the same characters for the browser (1080 lines, ink, alpha)
#   text/mono/<h>.pgm, screens/mono/<h>.png, messages.json "mono", "logview"   the v7 boot log's atlas
#
# Everything is drawn in plain Elixir (flat rectangles, alpha blending, PNG via :zlib) except the letters:
# those come from libvips' text renderer (pango + freetype) through the Vix library, the one dependency.
# Run it where Vix's precompiled libvips works: Linux, so in the Elixir image on the build VM:
#
#   docker run --rm -v "$PWD:$PWD" -w "$PWD" hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim \
#       elixir scripts/render-splash.exs alnasl/alnasl-src.tar fonts/DejaVuSansMono.ttf --out /tmp/splash-new --compare overlay/usr/share/alnasl/splash
#
# (Mix.install fetches vix and its precompiled NIF on the first run: needs the network, ~30 MB.)
#
# Fonts. Nunito (SIL OFL 1.1) comes out of Alnasl's source tar as a variable woff2 and is used at weights 700
# (titles) and 500 (lines). The renderer needs libvips' freetype to read woff2 (brotli) and fontconfig to offer
# the "Nunito Bold" / "Nunito Medium" instances; the script checks that the font really loaded (it renders
# with the font and with a name that does not exist and refuses if the two are identical) and that the two
# weights differ. If the check fails, convert the font once to a plain TTF elsewhere and pass it with --nunito.
#
# Not byte-identical to PIL: letter shapes come from another rasteriser, so coverage bytes, and with them PNG
# bytes, differ. Sizes can differ by a pixel as well (PIL: width = rounded advance + 2, height = ascent +
# descent; here: the width/height of pango's logical box). That is what --compare is for: if the heights and the
# advances in messages.json come out the same as the committed ones, the layout is the same; if not, the
# alnasl-splash painter (which centres from the file sizes) still works, but check the pictures by eye.
Mix.install([{:vix, ">= 0.31.0"}])

defmodule Json do
  # json.dump(indent=1, ensure_ascii=False): objects are {:obj, [{key, value}]} to keep their order.
  def o(kvs), do: {:obj, kvs}
  def encode(v), do: enc(v, 0) <> "\n"

  defp enc({:obj, []}, _), do: "{}"

  defp enc({:obj, kvs}, l) do
    pad = String.duplicate(" ", l + 1)
    body = Enum.map_join(kvs, ",\n", fn {k, v} -> pad <> str(k) <> ": " <> enc(v, l + 1) end)
    "{\n" <> body <> "\n" <> String.duplicate(" ", l) <> "}"
  end

  defp enc([], _), do: "[]"

  defp enc(list, l) when is_list(list) do
    pad = String.duplicate(" ", l + 1)
    "[\n" <> Enum.map_join(list, ",\n", &(pad <> enc(&1, l + 1))) <> "\n" <> String.duplicate(" ", l) <> "]"
  end

  defp enc(nil, _), do: "null"
  defp enc(true, _), do: "true"
  defp enc(false, _), do: "false"
  defp enc(n, _) when is_integer(n), do: Integer.to_string(n)
  defp enc(s, _) when is_binary(s), do: str(s)

  @bs <<92>>
  defp str(s), do: <<34>> <> for(<<c::utf8 <- s>>, into: "", do: esc(c)) <> <<34>>
  defp esc(34), do: @bs <> <<34>>
  defp esc(92), do: @bs <> @bs
  defp esc(10), do: @bs <> "n"
  defp esc(13), do: @bs <> "r"
  defp esc(9), do: @bs <> "t"
  defp esc(c) when c < 0x20, do: @bs <> "u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
  defp esc(c), do: <<c::utf8>>
end

defmodule Img do
  @moduledoc "A tiny RGB picture: a tuple of rows (binaries, 3 bytes a pixel), flat rectangles and alpha blending."

  def new(w, h, {r, g, b}), do: %{w: w, h: h, rows: Tuple.duplicate(:binary.copy(<<r, g, b>>, w), h)}

  # Inclusive corners, clipped to the picture (PIL's rectangle([x0, y0, x1, y1])).
  def rect(img, x0, y0, x1, y1, {r, g, b}) do
    x0 = max(x0, 0)
    y0 = max(y0, 0)
    x1 = min(x1, img.w - 1)
    y1 = min(y1, img.h - 1)

    if x1 < x0 or y1 < y0 do
      img
    else
      span = :binary.copy(<<r, g, b>>, x1 - x0 + 1)

      rows =
        Enum.reduce(y0..y1, img.rows, fn y, rows ->
          row = elem(rows, y)
          put_elem(rows, y, binary_part(row, 0, x0 * 3) <> span <> binary_part(row, (x1 + 1) * 3, (img.w - 1 - x1) * 3))
        end)

      %{img | rows: rows}
    end
  end

  # PIL's rectangle(outline=, width=): a border of `lw` pixels inside the box.
  def outline(img, x0, y0, x1, y1, lw, c) do
    img
    |> rect(x0, y0, x1, y0 + lw - 1, c)
    |> rect(x0, y1 - lw + 1, x1, y1, c)
    |> rect(x0, y0, x0 + lw - 1, y1, c)
    |> rect(x1 - lw + 1, y0, x1, y1, c)
  end

  # Paste a flat colour through an 8-bit coverage mask ({w, h, bytes}) with its top-left at (x, y).
  def paste(img, nil, _x, _y, _c), do: img

  def paste(img, {cw, ch, cov}, x, y, {r, g, b}) do
    rows =
      Enum.reduce(0..(ch - 1), img.rows, fn cy, rows ->
        yy = y + cy

        if yy < 0 or yy >= img.h or x < 0 or x + cw > img.w do
          rows
        else
          row = elem(rows, yy)
          seg = blend(binary_part(cov, cy * cw, cw), binary_part(row, x * 3, cw * 3), r, g, b, [])
          put_elem(rows, yy, binary_part(row, 0, x * 3) <> seg <> binary_part(row, (x + cw) * 3, (img.w - x - cw) * 3))
        end
      end)

    %{img | rows: rows}
  end

  defp blend(<<>>, <<>>, _, _, _, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp blend(<<a, cov::binary>>, <<dr, dg, db, dst::binary>>, r, g, b, acc),
    do: blend(cov, dst, r, g, b, [<<mix(r, dr, a), mix(g, dg, a), mix(b, db, a)>> | acc])

  defp mix(s, d, a), do: div(s * a + d * (255 - a) + 127, 255)
end

defmodule Png do
  @sig <<137, 80, 78, 71, 13, 10, 26, 10>>

  # rows: list of binaries of w * channels bytes; channels 3 = RGB, 4 = RGBA; 8 bit, filter 0.
  def write(path, rows, w, h, channels) do
    raw = IO.iodata_to_binary(Enum.map(rows, &[0, &1]))
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9)
    data = IO.iodata_to_binary(:zlib.deflate(z, raw, :finish))
    :zlib.close(z)
    ihdr = <<w::32, h::32, 8, if(channels == 4, do: 6, else: 2), 0, 0, 0>>
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @sig <> chunk("IHDR", ihdr) <> chunk("IDAT", data) <> chunk("IEND", ""))
  end

  defp chunk(type, data), do: <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>

  def write_img(path, img), do: write(path, Tuple.to_list(img.rows), img.w, img.h, 3)

  # A flat colour with a per-pixel alpha from an 8-bit coverage mask.
  def write_alpha(path, {w, h, cov}, {r, g, b}) do
    rows =
      for y <- 0..(h - 1) do
        for <<a <- binary_part(cov, y * w, w)>>, into: "", do: <<r, g, b, a>>
      end

    write(path, rows, w, h, 4)
  end

  def dims(path) do
    <<_::binary-size(16), w::32, h::32, _::binary>> = File.read!(path)
    {w, h}
  end
end

defmodule Text do
  @moduledoc "Letters as 8-bit coverage {w, h, bytes} via libvips' text renderer (pango + freetype)."
  alias Vix.Vips.{Image, Operation}

  def raster(text, family, px, fontfile) do
    font = "#{family} #{px}"
    safe = text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

    img =
      case Operation.text(safe, font: font, fontfile: fontfile, dpi: 72) do
        {:ok, {img, _extra}} -> img
        {:ok, img} -> img
        {:error, why} -> raise "text #{inspect(text)} in #{font}: #{inspect(why)}"
      end

    bin =
      case Image.write_to_binary(img) do
        {:ok, b} -> b
        b when is_binary(b) -> b
      end

    {Image.width(img), Image.height(img), bin}
  end

  # The line as an 8-bit coverage image: width = the text's advance + 2 (one column on each side), height =
  # the line box; the letters start one column in. nil for an empty text.
  def coverage("", _family, _px, _file), do: nil

  def coverage(text, family, px, file) do
    {w, h, bin} = raster(text, family, px, file)
    {w + 2, h, pad_left(bin, w, h, 1, w + 2)}
  end

  defp pad_left(bin, w, h, left, total) do
    right = total - w - left
    IO.iodata_to_binary(for y <- 0..(h - 1), do: [:binary.copy(<<0>>, left), binary_part(bin, y * w, w), :binary.copy(<<0>>, right)])
  end

  # One character in a cell of adv x lh, its line box starting `top` rows down (clipped to the cell).
  def cell(ch, family, px, file, adv, lh, top) do
    if ch == " " do
      :binary.copy(<<0>>, adv * lh)
    else
      {w, h, bin} = raster(ch, family, px, file)

      IO.iodata_to_binary(
        for y <- 0..(lh - 1) do
          sy = y - top

          if sy < 0 or sy >= h do
            :binary.copy(<<0>>, adv)
          else
            n = min(w, adv)
            [binary_part(bin, sy * w, n), :binary.copy(<<0>>, adv - n)]
          end
        end
      )
    end
  end

  # PIL's round(font.getlength(ch)) and the line height ascent + descent, from the rendered logical box.
  def metrics(family, px, file) do
    {w, h, _} = raster("M", family, px, file)
    {w, h}
  end

  # Refuse a font that did not load (pango silently falls back to some other font) or a weight that is not there.
  def check_fonts(nunito, mono) do
    for {file, fam, other} <- [{nunito, "Nunito", "Nunito Bold"}, {nunito, "Nunito Medium", "Nunito Bold"}, {mono, "DejaVu Sans Mono", nil}] do
      a = raster("Wiqg", fam, 40, file)
      b = raster("Wiqg", "No Such Font Family Zz", 40, file)
      if a == b, do: raise("the font #{fam} (#{file}) did not load in libvips: it renders like a missing font. See the header of render-splash.exs.")
      if other && raster("Wiqg", other, 40, file) == a, do: raise("#{fam} and #{other} render the same: no weight axis. See the header of render-splash.exs.")
    end

    :ok
  end
end

defmodule Splash do
  # Alnasl's dark theme (assets/css/app.css): --bg, --ink, --accent. Dim and outline are ours.
  @bg {0x16, 0x17, 0x1A}
  @ink {0xE9, 0xE9, 0xE6}
  @accent {0xE2, 0xA0, 0x8C}
  @dim {0xA3, 0xA3, 0x9F}
  @outline {0x55, 0x56, 0x5A}

  # Geometry at 1080 lines; everything scales with the screen height (s = H / 1080).
  # The mark: 24-unit grid, 1 unit = 15 px, squares 6 units, gaps 1; 7 of the 9 squares.
  @mark [{0, 0, :ink}, {1, 0, :ink}, {2, 0, :accent}, {1, 1, :ink}, {2, 1, :ink}, {0, 2, :ink}, {2, 2, :ink}]
  @sq 90
  @step 105
  @title_y 214
  @title_px 46
  @sub_y 282
  @sub_px 30
  @dots_y 346
  @dot 14
  @dot_gap 10
  @bar_w 360
  @bar_h 6
  @bar_steps_y @dots_y + @dot + 2 * @dot_gap
  @glyphs [{"0", "0"}, {"1", "1"}, {"2", "2"}, {"3", "3"}, {"4", "4"}, {"5", "5"}, {"6", "6"}, {"7", "7"}, {"8", "8"}, {"9", "9"}, {".", "dot"}, {"v", "v"}, {"%", "pct"}]

  # v7 boot log. Offsets below the centre at 1080 lines, like the rest; the mark ends at +150.
  @mono_px 17
  @mono_lh 24

  # state: steps (done-so-far, total) or nil; EN and NL title and line.
  @states [
    {"boot", nil},
    {"firstboot-1", {{1, 3}, {"Setting up this box", "Giving it a name"}, {"Deze box wordt klaargemaakt", "Een naam geven"}}},
    {"firstboot-2", {{2, 3}, {"Setting up this box", "Unpacking the screen software: a few minutes, only this once"}, {"Deze box wordt klaargemaakt", "De schermsoftware uitpakken: een paar minuten, alleen deze keer"}}},
    {"firstboot-3", {{3, 3}, {"Setting up this box", "Starting Alnasl"}, {"Deze box wordt klaargemaakt", "Alnasl starten"}}},
    {"waiting", {nil, {"Starting Alnasl", ""}, {"Alnasl starten", ""}}},
    {"update-os", {nil, {"Updating", "Back in a minute"}, {"Bijwerken", "Zo terug"}}},
    {"update-reboot", {nil, {"Updating", "Restarting, back in a minute"}, {"Bijwerken", "Herstarten, zo terug"}}},
    {"update-finish", {nil, {"Updating", "Almost done"}, {"Bijwerken", "Bijna klaar"}}},
    {"update-app", {nil, {"Updating Alnasl", "Back in a minute"}, {"Alnasl bijwerken", "Zo terug"}}},
    {"reboot", {nil, {"Restarting", "Back in a minute"}, {"Herstarten", "Zo terug"}}},
    {"shutdown", {nil, {"Shutting down", "Unplug once the green light has stopped blinking"}, {"Afsluiten", "Stekker eruit zodra het groene lampje niet meer knippert"}}},
    {"reset-1", {{1, 4}, {"Erasing this box", "Stopping Alnasl"}, {"Deze box wissen", "Alnasl stoppen"}}},
    {"reset-2", {{2, 4}, {"Erasing this box", "Erasing the hall data"}, {"Deze box wissen", "De zaalgegevens wissen"}}},
    {"reset-3", {{3, 4}, {"Erasing this box", "Erasing settings, Wi-Fi and logs"}, {"Deze box wissen", "Instellingen, wifi en logs wissen"}}},
    {"reset-4", {{4, 4}, {"Erasing this box", "Restarting as new"}, {"Deze box wissen", "Opnieuw starten als nieuw"}}},
    # System updates (A/B, v6): the line is replaced by a value where it says so, and a bar shows progress.
    {"update-download", {nil, {"Downloading an update", ""}, {"Een update downloaden", ""}}},
    {"update-install", {nil, {"Installing the update", "Keep the power on"}, {"De update installeren", "Laat de stroom aan"}}},
    {"update-restart", {nil, {"Restarting into", ""}, {"Herstarten naar", ""}}},
    {"update-rolledback", {nil, {"The update did not work", "Back on the version it had before"}, {"De update werkte niet", "Terug op de vorige versie"}}}
  ]
  # Which states show a value (in the line's place) and a progress bar (in the step squares' place, or just
  # under them when the state has squares too: unpacking the kiosk at first boot).
  @value %{"update-download" => "pct", "update-restart" => "version"}
  @bar ["update-download", "update-install", "firstboot-2"]

  # Python's round(): halves go to the even neighbour.
  def pyround(x) do
    f = Float.floor(x * 1.0)
    d = x - f
    cond do
      d < 0.5 -> trunc(f)
      d > 0.5 -> trunc(f) + 1
      rem(trunc(f), 2) == 0 -> trunc(f)
      true -> trunc(f) + 1
    end
  end

  def draw_base(w, h) do
    s = h / 1080
    {cx, cy} = {div(w, 2), div(h, 2)}

    Enum.reduce(@mark, Img.new(w, h, @bg), fn {col, row, c}, im ->
      x0 = cx + pyround((col * @step - 150) * s)
      y0 = cy + pyround((row * @step - 150) * s)
      sz = pyround(@sq * s)
      Img.rect(im, x0, y0, x0 + sz - 1, y0 + sz - 1, if(c == :ink, do: @ink, else: @accent))
    end)
  end

  def draw_dots(im, nil), do: im

  def draw_dots(im, {done, total}) do
    s = im.h / 1080
    dot = pyround(@dot * s)
    gap = pyround(@dot_gap * s)
    x = div(im.w, 2) - div(total * dot + (total - 1) * gap, 2)
    y = div(im.h, 2) + pyround(@dots_y * s)
    lw = max(1, pyround(2 * s))

    Enum.reduce(1..total, {im, x}, fn i, {im, x} ->
      im =
        cond do
          i < done -> Img.rect(im, x, y, x + dot - 1, y + dot - 1, @ink)
          i == done -> Img.rect(im, x, y, x + dot - 1, y + dot - 1, @accent)
          true -> Img.outline(im, x, y, x + dot - 1, y + dot - 1, lw, @outline)
        end

      {im, x + dot + gap}
    end)
    |> elem(0)
  end

  # The empty track of the progress bar; the browser draws the filled part over it.
  def draw_bar(im, under_steps) do
    s = im.h / 1080
    w = pyround(@bar_w * s)
    hh = max(2, pyround(@bar_h * s))
    x = div(im.w, 2) - div(w, 2)
    y = div(im.h, 2) + pyround((if under_steps, do: @bar_steps_y, else: @dots_y) * s)
    Img.rect(im, x, y, x + w - 1, y + hh - 1, @outline)
  end

  def paste_line(im, nil, _top, _colour), do: im
  def paste_line(im, {cw, _h, _} = cov, top, colour), do: Img.paste(im, cov, div(im.w, 2) - div(cw, 2), div(im.h, 2) + top, colour)

  def write_pgm(path, nil), do: raise("no coverage for #{path}")

  def write_pgm(path, {w, h, bin}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "P5\n#{w} #{h}\n255\n" <> bin)
  end

  # One row of 95 fixed cells (ASCII 32-126) per height: coverage for the painter, white-on-alpha for the
  # browser. Cell width is the font's advance rounded; the text sits in the middle of the line box.
  def mono_atlas(out, file) do
    for h <- [1080, 720] do
      px = pyround(@mono_px * h / 1080)
      lh = pyround(@mono_lh * h / 1080)
      {adv, textheight} = Text.metrics("DejaVu Sans Mono", px, file)
      top = Integer.floor_div(lh - textheight, 2)
      cells = for i <- 0..94, do: Text.cell(<<32 + i::utf8>>, "DejaVu Sans Mono", px, file, adv, lh, top)

      bin =
        IO.iodata_to_binary(
          for y <- 0..(lh - 1), c <- cells, do: binary_part(c, y * adv, adv)
        )

      atlas = {95 * adv, lh, bin}
      write_pgm(Path.join([out, "text", "mono", "#{h}.pgm"]), atlas)
      Png.write_alpha(Path.join([out, "screens", "mono", "#{h}.png"]), atlas, {255, 255, 255})
      {Integer.to_string(h), Json.o([{"adv", adv}, {"lh", lh}, {"first", 32}, {"count", 95}])}
    end
  end

  def logview do
    Json.o([
      {"status_y", 178},
      {"log_y", 220},
      {"log_y_steps", 410},
      {"bottom", 18},
      {"margin", 60},
      {"max_chars", 150},
      # the newest line is drawn at full strength, older ones fade over BG: 255 = the colour itself
      {"fade", [255, 225, 195, 170, 145, 120, 100, 85]},
      # by source (bootlog.py COLOURS); errors are never faded
      {"colours",
       Json.o([
         {"kernel", [0x8A, 0x8B, 0x90]},
         {"systemd", Tuple.to_list(@ink)},
         {"network", [0x9D, 0xB8, 0xD6]},
         {"app", [0xA9, 0xC7, 0xB0]},
         {"box", Tuple.to_list(@dim)},
         {"error", Tuple.to_list(@accent)},
         {"status", Tuple.to_list(@ink)}
       ])}
    ])
  end

  def run(out, nunito, mono) do
    Text.check_fonts(nunito, mono)
    File.mkdir_p!(out)
    Png.write_img(Path.join(out, "alnasl-splash.png"), draw_base(1920, 1080))

    # The glyphs of a value line: coverage for the painter, ink-on-alpha PNGs for the browser.
    glyph_meta =
      for h <- [1080, 720] do
        px = pyround(@sub_px * h / 1080)
        fam = "Nunito Medium"

        {advs, height} =
          Enum.map_reduce(@glyphs, 0, fn {ch, name}, _ ->
            cov = Text.coverage(ch, fam, px, nunito)
            write_pgm(Path.join([out, "text", "glyphs", "#{h}", name <> ".pgm"]), cov)
            if h == 1080, do: Png.write_alpha(Path.join([out, "screens", "glyphs", name <> ".png"]), cov, @ink)
            {Text.raster(ch, fam, px, nunito) |> elem(0), elem(cov, 1)}
          end)

        {Integer.to_string(h),
         Json.o([
           {"advance", Json.o(Enum.zip_with(@glyphs, advs, fn {ch, _}, a -> {ch, a} end))},
           {"names", Json.o(@glyphs)},
           {"height", height}
         ])}
      end

    states =
      for {key, spec} <- @states do
        case spec do
          nil ->
            {key, Json.o([{"steps", nil}, {"text", false}])}

          {steps, {et, es}, {nt, ns}} ->
            for lang_text <- [{"en", et, es}, {"nl", nt, ns}], h <- [1080, 720] do
              {lang, title, line} = lang_text
              s = h / 1080
              ct = Text.coverage(title, "Nunito Bold", pyround(@title_px * s), nunito)
              cs = Text.coverage(line, "Nunito Medium", pyround(@sub_px * s), nunito)
              base = Path.join([out, "text", lang, "#{key}.#{h}"])
              write_pgm(base <> ".title.pgm", ct)
              if cs, do: write_pgm(base <> ".sub.pgm", cs)

              if h == 1080 do
                im =
                  draw_base(1920, 1080)
                  |> paste_line(ct, @title_y, @ink)
                  |> paste_line(cs, @sub_y, @dim)
                  |> draw_dots(steps)

                im = if key in @bar, do: draw_bar(im, steps != nil), else: im
                Png.write_img(Path.join([out, "screens", lang, key <> ".png"]), im)
              end
            end

            {key,
             Json.o([
               {"steps", if(steps, do: Tuple.to_list(steps), else: nil)},
               {"text", true},
               {"value", @value[key]},
               {"bar", key in @bar},
               {"en", Json.o([{"title", et}, {"sub", es}])},
               {"nl", Json.o([{"title", nt}, {"sub", ns}])}
             ])}
        end
      end

    meta =
      Json.o([
        {"geometry",
         Json.o([
           {"title_y", @title_y},
           {"sub_y", @sub_y},
           {"dots_y", @dots_y},
           {"dot", @dot},
           {"dot_gap", @dot_gap},
           {"bar_w", @bar_w},
           {"bar_h", @bar_h},
           {"bar_steps_y", @bar_steps_y}
         ])},
        {"glyphs", Json.o(glyph_meta)},
        {"states", Json.o(states)},
        {"mono", Json.o(mono_atlas(out, mono))},
        {"logview", logview()}
      ])

    File.write!(Path.join(out, "messages.json"), Json.encode(meta))
    IO.puts("written to #{out}")
  end
end

defmodule Compare do
  # Same files? Same picture sizes? Same messages.json, value by value?
  def run(new, ref) do
    files = Path.wildcard(Path.join(ref, "**/*")) |> Enum.filter(&File.regular?/1) |> Enum.map(&Path.relative_to(&1, ref)) |> Enum.sort()
    mine = Path.wildcard(Path.join(new, "**/*")) |> Enum.filter(&File.regular?/1) |> Enum.map(&Path.relative_to(&1, new)) |> Enum.sort()
    diffs =
      Enum.map(files -- mine, &"missing in the new output: #{&1}") ++
        Enum.map(mine -- files, &"not in the reference: #{&1}") ++
        for f <- files, f in mine, d = diff(f, Path.join(new, f), Path.join(ref, f)), do: "#{f}: #{d}"

    Enum.each(Enum.take(diffs, 60), &IO.puts("DIFF " <> &1))
    IO.puts("compared #{length(files)} reference files: #{length(diffs)} difference(s)")
    if diffs != [], do: System.halt(1)
  end

  defp diff(f, a, b) do
    cond do
      String.ends_with?(f, ".pgm") -> cmp(pgm(a), pgm(b))
      String.ends_with?(f, ".png") -> cmp(Png.dims(a), Png.dims(b))
      f == "messages.json" -> cmp_json(JSON.decode!(File.read!(a)), JSON.decode!(File.read!(b)))
      true -> nil
    end
  end

  defp pgm(path) do
    [_, dims | _] = String.split(File.read!(path), "\n", parts: 3)
    dims
  end

  defp cmp(x, x), do: nil
  defp cmp(x, y), do: "size #{inspect(x)} vs reference #{inspect(y)}"

  defp cmp_json(x, y) do
    d = flat(x, "") |> Enum.reject(fn {k, v} -> Map.get(Map.new(flat(y, "")), k) == v end)
    ks = Map.keys(Map.new(flat(y, ""))) -- Map.keys(Map.new(flat(x, "")))
    if d == [] and ks == [], do: nil, else: "#{length(d)} value(s) differ, e.g. #{inspect(Enum.take(d, 3))}; #{length(ks)} key(s) missing"
  end

  defp flat(m, p) when is_map(m), do: Enum.flat_map(m, fn {k, v} -> flat(v, p <> "/" <> k) end)
  defp flat(l, p) when is_list(l), do: l |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> flat(v, p <> "[#{i}]") end)
  defp flat(v, p), do: [{p, v}]
end

{opts, args, _} = OptionParser.parse(System.argv(), strict: [out: :string, nunito: :string, compare: :string])
root = Path.expand("..", Path.dirname(__ENV__.file))
out = opts[:out] || Path.join([root, "overlay", "usr", "share", "alnasl", "splash"])

{tar, mono} =
  case args do
    [t] -> {t, Path.join([root, "fonts", "DejaVuSansMono.ttf"])}
    [t, m] -> {t, m}
    _ -> IO.puts(:stderr, "usage: elixir scripts/render-splash.exs alnasl-src.tar [DejaVuSansMono.ttf] [--out DIR] [--nunito FILE] [--compare DIR]"); System.halt(2)
  end

nunito =
  opts[:nunito] ||
    (
      tmp = Path.join(System.tmp_dir!(), "render-splash-font")
      File.mkdir_p!(tmp)
      member = ~c"priv/theme_packs/toon/fonts/nunito-latin.woff2"
      :ok = :erl_tar.extract(String.to_charlist(tar), [{:files, [member]}, {:cwd, String.to_charlist(tmp)}])
      Path.join(tmp, "priv/theme_packs/toon/fonts/nunito-latin.woff2")
    )

Splash.run(out, nunito, mono)
if opts[:compare], do: Compare.run(out, opts[:compare])
