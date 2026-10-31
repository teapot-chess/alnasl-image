defmodule AlnaslSetup.QR do
  @moduledoc """
  A QR code, byte mode, written as a plain PNG. OTP only.

  What the box needs is one symbol, the Wi-Fi join code of its setup hotspot (alnasl-hotspot-qr.png on
  the boot partition), so this does byte mode, error correction level M, versions 1 to 10, and nothing
  else. That is up to 213 bytes, which is more than a WIFI: payload with a 63-character password can be
  even after escaping.

      encode(data, mask \\\\ nil)  -> list of rows of booleans (true = dark), quiet zone not included
      png(matrix, scale, border) -> bytes of a greyscale PNG
      wifi_payload(ssid, pw)     -> the standard "WIFI:T:WPA;S:...;P:...;;" text
      wifi_png(ssid, pw)         -> the PNG of that

  The structure follows ISO/IEC 18004 (and every QR encoder that ever copied it): finder, separator,
  timing and alignment patterns, the format and version bits, the data in the zigzag order, eight masks
  with the standard penalty rules. test/qr_test.exs decodes what this draws, independently, and checks
  the Reed-Solomon codes, because "looks like a QR code" is not a test. It is a port of the Python
  encoder this replaces and gives the same symbol and the same PNG bytes for the same input.
  """
  import Bitwise

  # Level M, versions 1..10: {ECC codewords per block, number of blocks}.
  @ecc_m %{
    1 => {10, 1},
    2 => {16, 1},
    3 => {26, 1},
    4 => {18, 2},
    5 => {24, 2},
    6 => {16, 4},
    7 => {18, 4},
    8 => {22, 4},
    9 => {22, 5},
    10 => {26, 5}
  }
  @max_version 10
  # the two format bits of level M (L=1, M=0, Q=3, H=2)
  @format_ecl_m 0

  # ------------------------------------------------------------------ GF(256) --
  def gf_mul(x, y) do
    Enum.reduce(7..0//-1, 0, fn i, z ->
      z = bxor(z <<< 1, (z >>> 7) * 0x11D)
      bxor(z, (y >>> i &&& 1) * x)
    end)
  end

  @doc "The generator polynomial with roots a^0 .. a^(degree-1), highest coefficient (1) left out."
  def rs_divisor(degree) do
    start = List.duplicate(0, degree - 1) ++ [1]

    {result, _root} =
      Enum.reduce(1..degree, {start, 1}, fn _, {res, root} ->
        shifted = tl(res) ++ [0]
        res = Enum.zip_with(res, shifted, fn a, b -> bxor(gf_mul(a, root), b) end)
        {res, gf_mul(root, 0x02)}
      end)

    result
  end

  def rs_remainder(data, divisor) do
    Enum.reduce(data, List.duplicate(0, length(divisor)), fn b, [first | rest] ->
      factor = bxor(b, first)
      Enum.zip_with(rest ++ [0], divisor, fn r, coef -> bxor(r, gf_mul(coef, factor)) end)
    end)
  end

  # ------------------------------------------------------------------- layout --
  def size_of(version), do: version * 4 + 17

  def raw_data_modules(version) do
    result = (16 * version + 128) * version + 64

    if version >= 2 do
      n = div(version, 7) + 2
      result = result - ((25 * n - 10) * n - 55)
      if version >= 7, do: result - 36, else: result
    else
      result
    end
  end

  def alignment_positions(1), do: []

  def alignment_positions(version) do
    n = div(version, 7) + 2
    step = div(version * 8 + n * 3 + 5, n * 4 - 4) * 2
    size = size_of(version)
    [6 | Enum.sort(for i <- 0..(n - 2), do: size - 7 - i * step)]
  end

  @doc "Data codewords at level M."
  def data_capacity(version) do
    {ecc, blocks} = Map.fetch!(@ecc_m, version)
    div(raw_data_modules(version), 8) - ecc * blocks
  end

  def format_bits(mask, ecl \\ @format_ecl_m) do
    data = ecl <<< 3 ||| mask

    rem =
      Enum.reduce(1..10, data, fn _, rem -> bxor(rem <<< 1, (rem >>> 9) * 0x537) end)

    bxor(data <<< 10 ||| rem, 0x5412)
  end

  def version_bits(version) do
    rem = Enum.reduce(1..12, version, fn _, rem -> bxor(rem <<< 1, (rem >>> 11) * 0x1F25) end)
    version <<< 12 ||| rem
  end

  # The grid is a map {x, y} => dark?, and a set of the function-pattern cells (no data goes there).
  defp new_grid(version) do
    n = size_of(version)

    %{
      version: version,
      n: n,
      dark: Map.new(for(x <- 0..(n - 1), y <- 0..(n - 1), do: {{x, y}, false})),
      func: MapSet.new()
    }
  end

  defp set_func(g, x, y, dark), do: %{g | dark: Map.put(g.dark, {x, y}, dark), func: MapSet.put(g.func, {x, y})}

  defp draw_function_patterns(g) do
    n = g.n

    # timing
    g = Enum.reduce(0..(n - 1), g, fn i, g -> g |> set_func(6, i, rem(i, 2) == 0) |> set_func(i, 6, rem(i, 2) == 0) end)

    # finders with their separators
    g =
      for {cx, cy} <- [{3, 3}, {n - 4, 3}, {3, n - 4}], dy <- -4..4, dx <- -4..4, reduce: g do
        g ->
          x = cx + dx
          y = cy + dy

          if x >= 0 and x < n and y >= 0 and y < n,
            do: set_func(g, x, y, max(abs(dx), abs(dy)) not in [2, 4]),
            else: g
      end

    pos = alignment_positions(g.version)
    last = length(pos) - 1

    g =
      for {ay, i} <- Enum.with_index(pos), {ax, j} <- Enum.with_index(pos), reduce: g do
        g ->
          if (i == 0 and j == 0) or (i == 0 and j == last) or (i == last and j == 0) do
            g
          else
            # those three corners belong to the finders
            for dy <- -2..2, dx <- -2..2, reduce: g do
              g -> set_func(g, ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
            end
          end
      end

    # reserves the format area; drawn again for real once the mask is chosen
    g = draw_format(g, 0)

    if g.version >= 7 do
      bits = version_bits(g.version)

      Enum.reduce(0..17, g, fn i, g ->
        b = (bits >>> i &&& 1) == 1
        a = n - 11 + rem(i, 3)
        c = div(i, 3)
        g |> set_func(a, c, b) |> set_func(c, a, b)
      end)
    else
      g
    end
  end

  defp draw_format(g, mask) do
    bits = format_bits(mask)
    n = g.n
    bit = fn i -> (bits >>> i &&& 1) == 1 end

    g = Enum.reduce(0..5, g, fn i, g -> set_func(g, 8, i, bit.(i)) end)
    g = g |> set_func(8, 7, bit.(6)) |> set_func(8, 8, bit.(7)) |> set_func(7, 8, bit.(8))
    g = Enum.reduce(9..14, g, fn i, g -> set_func(g, 14 - i, 8, bit.(i)) end)
    g = Enum.reduce(0..7, g, fn i, g -> set_func(g, n - 1 - i, 8, bit.(i)) end)
    g = Enum.reduce(8..14, g, fn i, g -> set_func(g, 8, n - 15 + i, bit.(i)) end)
    # the dark module, always there
    set_func(g, 8, n - 8, true)
  end

  defp draw_codewords(g, codewords) do
    n = g.n
    total = length(codewords) * 8
    cw = List.to_tuple(codewords)
    rights = Enum.to_list((n - 1)..7//-2) ++ [5, 3, 1]

    {dark, i} =
      Enum.reduce(rights, {g.dark, 0}, fn right, acc ->
        upward = (right + 1 &&& 2) == 0

        Enum.reduce(0..(n - 1), acc, fn vert, acc ->
          y = if upward, do: n - 1 - vert, else: vert

          Enum.reduce(0..1, acc, fn j, {dark, i} = acc ->
            x = right - j

            if not MapSet.member?(g.func, {x, y}) and i < total do
              bit = (elem(cw, i >>> 3) >>> (7 - (i &&& 7)) &&& 1) == 1
              {Map.put(dark, {x, y}, bit), i + 1}
            else
              acc
            end
          end)
        end)
      end)

    ^total = i
    %{g | dark: dark}
  end

  defp mask?(0, x, y), do: rem(x + y, 2) == 0
  defp mask?(1, _x, y), do: rem(y, 2) == 0
  defp mask?(2, x, _y), do: rem(x, 3) == 0
  defp mask?(3, x, y), do: rem(x + y, 3) == 0
  defp mask?(4, x, y), do: rem(div(x, 3) + div(y, 2), 2) == 0
  defp mask?(5, x, y), do: rem(x * y, 2) + rem(x * y, 3) == 0
  defp mask?(6, x, y), do: rem(rem(x * y, 2) + rem(x * y, 3), 2) == 0
  defp mask?(7, x, y), do: rem(rem(x + y, 2) + rem(x * y, 3), 2) == 0

  defp apply_mask(g, mask) do
    dark =
      for y <- 0..(g.n - 1), x <- 0..(g.n - 1), not MapSet.member?(g.func, {x, y}), mask?(mask, x, y), reduce: g.dark do
        dark -> Map.update!(dark, {x, y}, &(not &1))
      end

    %{g | dark: dark}
  end

  defp to_matrix(g), do: for(y <- 0..(g.n - 1), do: for(x <- 0..(g.n - 1), do: Map.fetch!(g.dark, {x, y})))

  @pat1 [true, false, true, true, true, false, true, false, false, false, false]
  @pat2 Enum.reverse(@pat1)

  @doc "The four rules of the standard. Any mask decodes; this only picks the one scanners like best."
  def penalty(m) do
    n = length(m)
    cols = m |> Enum.zip() |> Enum.map(&Tuple.to_list/1)

    score = Enum.reduce(m ++ cols, 0, fn line, score -> score + line_penalty(line, n) end)

    rows = List.to_tuple(Enum.map(m, &List.to_tuple/1))
    get = fn y, x -> rows |> elem(y) |> elem(x) end

    blocks =
      for y <- 0..(n - 2), x <- 0..(n - 2), reduce: 0 do
        acc ->
          c = get.(y, x)
          if c == get.(y, x + 1) and c == get.(y + 1, x) and c == get.(y + 1, x + 1), do: acc + 3, else: acc
      end

    dark = m |> List.flatten() |> Enum.count(& &1)
    total = n * n
    k = div(abs(dark * 20 - total * 10) + total - 1, total) - 1
    score + blocks + k * 10
  end

  defp line_penalty(line, n) do
    {run_score, run, _prev} =
      Enum.reduce(line, {0, 0, :none}, fn v, {score, run, prev} ->
        cond do
          v == prev -> {score, run + 1, prev}
          run >= 5 -> {score + 3 + run - 5, 1, v}
          true -> {score, 1, v}
        end
      end)

    run_score = if run >= 5, do: run_score + 3 + run - 5, else: run_score

    t = List.to_tuple(line)

    finders =
      Enum.count(0..(n - 11)//1, fn i ->
        seg = for k <- i..(i + 10), do: elem(t, k)
        seg == @pat1 or seg == @pat2
      end)

    run_score + finders * 40
  end

  # ------------------------------------------------------------------- encode --
  defp length_bits(version) when version <= 9, do: 8
  defp length_bits(_), do: 16

  defp data_codewords(data, version) do
    cap_bits = data_capacity(version) * 8
    lbits = length_bits(version)
    bits = <<0b0100::4, byte_size(data)::size(lbits), data::binary>>
    if bit_size(bits) > cap_bits, do: raise(ArgumentError, "too long for version #{version}")
    # terminator, then up to a whole byte
    bits = <<bits::bitstring, 0::size(min(4, cap_bits - bit_size(bits)))>>
    bits = <<bits::bitstring, 0::size(rem(8 - rem(bit_size(bits), 8), 8))>>
    out = for <<b <- bits>>, do: b
    pad(out, div(cap_bits, 8) - length(out), 0xEC)
  end

  defp pad(out, n, _) when n <= 0, do: out
  defp pad(out, n, p), do: pad(out ++ [p], n - 1, bxor(p, bxor(0xEC, 0x11)))

  defp interleave(data, version) do
    {ecc, nblocks} = Map.fetch!(@ecc_m, version)
    raw = div(raw_data_modules(version), 8)
    nshort = nblocks - rem(raw, nblocks)
    short_len = div(raw, nblocks)
    div_ = rs_divisor(ecc)

    {blocks, _} =
      Enum.map_reduce(0..(nblocks - 1), data, fn i, rest ->
        dlen = short_len - ecc + if(i < nshort, do: 0, else: 1)
        {dat, rest} = Enum.split(rest, dlen)
        # a short block gets a placeholder where the long ones have their extra data byte
        {{dat ++ if(i < nshort, do: [0], else: []), rs_remainder(dat, div_), i}, rest}
      end)

    blocks = for {d, e, i} <- blocks, do: {d ++ e, i}
    tuples = for {blk, i} <- blocks, do: {List.to_tuple(blk), i}

    out =
      for pos <- 0..(tuple_size(elem(hd(tuples), 0)) - 1),
          {blk, j} <- tuples,
          pos != short_len - ecc or j >= nshort,
          do: elem(blk, pos)

    ^raw = length(out)
    out
  end

  @doc """
  The symbol for `data` (a binary; the smallest version 1-10 that holds it), as a list of rows of
  booleans. `mask` fixes the mask (0-7); `nil` picks the one with the lowest penalty. Raises
  ArgumentError when the data is more than a version 10-M symbol holds.
  """
  def encode(data, mask \\ nil) when is_binary(data) do
    version =
      Enum.find(1..@max_version, fn v -> 4 + length_bits(v) + 8 * byte_size(data) <= data_capacity(v) * 8 end) ||
        raise ArgumentError, "data too long for a version #{@max_version} symbol"

    cw = interleave(data_codewords(data, version), version)
    base = version |> new_grid() |> draw_function_patterns() |> draw_codewords(cw)

    masks = if mask, do: [mask], else: Enum.to_list(0..7)

    {_p, best} =
      masks
      |> Enum.map(fn m ->
        matrix = base |> apply_mask(m) |> draw_format(m) |> to_matrix()
        {penalty(matrix), matrix}
      end)
      |> Enum.min_by(&elem(&1, 0))

    best
  end

  # ---------------------------------------------------------------------- PNG --
  @doc "8-bit greyscale PNG, black on white, `border` modules of quiet zone (the standard asks for 4)."
  def png(matrix, scale \\ 10, border \\ 4) do
    n = length(matrix)
    side = (n + 2 * border) * scale
    white = :binary.copy(<<0xFF>>, side)
    rows = List.to_tuple(Enum.map(matrix, &List.to_tuple/1))

    body =
      for y <- -border..(n + border - 1) do
        line =
          if y >= 0 and y < n do
            row = elem(rows, y)

            for x <- -border..(n + border - 1), into: <<>> do
              v = if x >= 0 and x < n and elem(row, x), do: 0, else: 255
              :binary.copy(<<v>>, scale)
            end
          else
            white
          end

        :binary.copy(<<0, line::binary>>, scale)
      end

    ihdr = <<side::32, side::32, 8, 0, 0, 0, 0>>

    [
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", ihdr),
      chunk("IDAT", deflate9(IO.iodata_to_binary(body))),
      chunk("IEND", <<>>)
    ]
    |> IO.iodata_to_binary()
  end

  defp chunk(kind, body), do: <<byte_size(body)::32, kind::binary, body::binary, :erlang.crc32(kind <> body)::32>>

  # zlib.compress(data, 9): the zlib header 78 DA and the best compression, as Python wrote it.
  defp deflate9(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, 9)
      out = z |> :zlib.deflate(data, :finish) |> IO.iodata_to_binary()
      :ok = :zlib.deflateEnd(z)
      out
    after
      :zlib.close(z)
    end
  end

  # --------------------------------------------------------------------- Wi-Fi --
  @doc "The WIFI: scheme's escapes: backslash before \\\\ ; , : and \\\"."
  def wifi_escape(s) do
    for <<c <- s>>, into: <<>> do
      if c in [?\\, ?;, ?,, ?:, ?"], do: <<?\\, c>>, else: <<c>>
    end
  end

  def wifi_payload(ssid, password), do: "WIFI:T:WPA;S:#{wifi_escape(ssid)};P:#{wifi_escape(password)};;"

  def wifi_png(ssid, password, scale \\ 10), do: ssid |> wifi_payload(password) |> encode() |> png(scale)
end
