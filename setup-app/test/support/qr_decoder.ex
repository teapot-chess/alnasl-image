defmodule AlnaslSetup.Test.QRDecoder do
  @moduledoc """
  An independent QR decoder for the tests (port of scripts/test-qr.py's), by decoding what the
  encoder draws. It shares no code with `AlnaslSetup.QR` and takes its numbers from the standard's
  tables (alignment positions, block structure), not from the encoder's formulas: it reads the format
  bits from both copies, rebuilds the function-pattern map, unmasks, reads the zigzag, de-interleaves,
  checks every Reed-Solomon syndrome is zero and parses the byte-mode segment. A symbol that passes all
  of that is one a phone can read.
  """
  import Bitwise

  # ISO/IEC 18004 table E.1 and table 9 (level M): alignment centres; blocks as {count, total, data}.
  @align %{
    1 => [],
    2 => [6, 18],
    3 => [6, 22],
    4 => [6, 26],
    5 => [6, 30],
    6 => [6, 34],
    7 => [6, 22, 38],
    8 => [6, 24, 42],
    9 => [6, 26, 46],
    10 => [6, 28, 50]
  }
  @blocks_m %{
    1 => [{1, 26, 16}],
    2 => [{1, 44, 28}],
    3 => [{1, 70, 44}],
    4 => [{2, 50, 32}],
    5 => [{2, 67, 43}],
    6 => [{4, 43, 27}],
    7 => [{4, 49, 31}],
    8 => [{2, 60, 38}, {2, 61, 39}],
    9 => [{3, 58, 36}, {2, 59, 37}],
    10 => [{4, 69, 43}, {1, 70, 44}]
  }

  def align, do: @align

  # mask conditions as the standard writes them: i = row, j = column
  defp mask_cond(0, i, j), do: rem(i + j, 2) == 0
  defp mask_cond(1, i, _), do: rem(i, 2) == 0
  defp mask_cond(2, _, j), do: rem(j, 3) == 0
  defp mask_cond(3, i, j), do: rem(i + j, 3) == 0
  defp mask_cond(4, i, j), do: rem(div(i, 2) + div(j, 3), 2) == 0
  defp mask_cond(5, i, j), do: rem(i * j, 2) + rem(i * j, 3) == 0
  defp mask_cond(6, i, j), do: rem(rem(i * j, 2) + rem(i * j, 3), 2) == 0
  defp mask_cond(7, i, j), do: rem(rem(i * j, 3) + rem(i + j, 2), 2) == 0

  def bch_format(data5) do
    g = 0b10100110111

    v =
      Enum.reduce(14..10//-1, data5 <<< 10, fn k, v ->
        if (v &&& 1 <<< k) != 0, do: bxor(v, g <<< (k - 10)), else: v
      end)

    bxor(data5 <<< 10 ||| v, 0b101010000010010)
  end

  # GF(256) with the QR polynomial 0x11D: exp and log tables.
  defp tables do
    {exp, log, _} =
      Enum.reduce(0..254, {%{}, %{}, 1}, fn i, {e, l, v} ->
        v2 = v <<< 1
        v2 = if (v2 &&& 0x100) != 0, do: bxor(v2, 0x11D), else: v2
        {Map.put(e, i, v), Map.put(l, v, i), v2}
      end)

    {exp, log}
  end

  @doc "Decodes a matrix (list of rows of booleans). `{:ok, {bytes, version, mask}}` or `{:error, why}`."
  def decode(matrix) do
    m = matrix |> Enum.map(&List.to_tuple/1) |> List.to_tuple()
    {:ok, do_decode(m)}
  catch
    {:assert, msg} -> {:error, msg}
  end

  defp assert!(true, _), do: :ok
  defp assert!(false, msg), do: throw({:assert, msg})

  defp get(m, r, c), do: m |> elem(r) |> elem(c)

  defp to_int(bools), do: bools |> Enum.map(&if(&1, do: "1", else: "0")) |> Enum.join() |> String.to_integer(2)

  defp do_decode(m) do
    n = tuple_size(m)
    ver = div(n - 17, 4)
    assert!(n == 17 + 4 * ver and ver in 1..10, "odd size #{n}")

    for {r0, c0} <- [{0, 0}, {0, n - 7}, {n - 7, 0}], r <- 0..6, c <- 0..6 do
      want = not ((r in [1, 5] and c in 1..5) or (c in [1, 5] and r in 1..5))
      assert!(get(m, r0 + r, c0 + c) == want, "finder pattern broken")
    end

    for k <- 8..(n - 9)//1 do
      assert!(get(m, 6, k) == (rem(k, 2) == 0) and get(m, k, 6) == (rem(k, 2) == 0), "timing pattern broken")
    end

    assert!(get(m, n - 8, 8), "dark module missing")

    c1 = Enum.map([0, 1, 2, 3, 4, 5, 7, 8], &get(m, 8, &1)) ++ Enum.map([7, 5, 4, 3, 2, 1, 0], &get(m, &1, 8))
    c2 = Enum.map((n - 1)..(n - 7)//-1, &get(m, &1, 8)) ++ Enum.map((n - 8)..(n - 1), &get(m, 8, &1))
    val1 = to_int(c1)
    assert!(val1 == to_int(c2), "the two format copies differ")
    table = Map.new(0..31, fn d -> {bch_format(d), d} end)
    assert!(Map.has_key?(table, val1), "format bits are not a BCH code word")
    d = table[val1]
    assert!(d >>> 3 == 0, "not level M")
    mask = d &&& 7

    # function map
    area = fn set, r0, c0, h, w ->
      for r <- max(r0, 0)..min(r0 + h - 1, n - 1), c <- max(c0, 0)..min(c0 + w - 1, n - 1), reduce: set do
        s -> MapSet.put(s, {r, c})
      end
    end

    f =
      MapSet.new()
      |> area.(0, 0, 9, 9)
      |> area.(0, n - 8, 9, 8)
      |> area.(n - 8, 0, 8, 9)
      |> area.(6, 0, 1, n)
      |> area.(0, 6, n, 1)

    pos = Map.fetch!(@align, ver)
    last = List.last(pos)

    f =
      for r <- pos, c <- pos, {r, c} not in [{6, 6}, {6, last}, {last, 6}], reduce: f do
        acc -> area.(acc, r - 2, c - 2, 5, 5)
      end

    f = if ver >= 7, do: f |> area.(0, n - 11, 6, 3) |> area.(n - 11, 0, 3, 6), else: f

    # zigzag, then codewords
    cw = m |> zigzag(f, n, mask, n - 1, true, []) |> Enum.chunk_every(8, 8, :discard) |> Enum.map(&to_int/1)

    # de-interleave
    spec = for {cnt, t, dl} <- Map.fetch!(@blocks_m, ver), _ <- 1..cnt, do: {t, dl}
    total = spec |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    assert!(length(cw) == total, "codeword count #{length(cw)}, expected #{total}")
    {t0, dl0} = hd(spec)
    eccn = t0 - dl0
    maxdl = spec |> Enum.map(&elem(&1, 1)) |> Enum.max()
    idx = Enum.with_index(spec)

    order =
      for(i <- 0..(maxdl - 1), {{_t, dl}, b} <- idx, i < dl, do: b) ++
        for(_ <- 1..eccn, {_, b} <- idx, do: b)

    blocks = order |> Enum.zip(cw) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    {exp, log} = tables()

    data =
      Enum.flat_map(idx, fn {{_t, dl}, b} ->
        blk = Map.fetch!(blocks, b)

        for i <- 0..(eccn - 1) do
          s =
            Enum.reduce(blk, 0, fn c, s ->
              bxor(if(s != 0, do: exp[rem(log[s] + i, 255)], else: 0), c)
            end)

          assert!(s == 0, "Reed-Solomon syndrome #{i} of block #{b} is not zero")
        end

        Enum.take(blk, dl)
      end)

    # byte mode
    bs = data |> Enum.map(&String.pad_leading(Integer.to_string(&1, 2), 8, "0")) |> Enum.join()
    assert!(String.slice(bs, 0, 4) == "0100", "not byte mode")
    cl = if ver <= 9, do: 8, else: 16
    length = bs |> String.slice(4, cl) |> String.to_integer(2)
    p = 4 + cl

    bytes =
      for i <- 0..(length - 1)//1, into: <<>> do
        <<String.to_integer(String.slice(bs, p + 8 * i, 8), 2)>>
      end

    {bytes, ver, mask}
  end

  defp zigzag(_m, _f, _n, _mask, col, _up, acc) when col <= 0, do: Enum.reverse(acc)

  defp zigzag(m, f, n, mask, col, up, acc) do
    col = if col == 6, do: 5, else: col
    rows = if up, do: (n - 1)..0//-1, else: 0..(n - 1)

    acc =
      for r <- rows, c <- [col, col - 1], not MapSet.member?(f, {r, c}), reduce: acc do
        a -> [get(m, r, c) != mask_cond(mask, r, c) | a]
      end

    zigzag(m, f, n, mask, col - 2, not up, acc)
  end

  @doc "Back from the PNG to modules: the centre pixel of each."
  def png_matrix(blob, scale, border) do
    <<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>> = blob
    {w, idat} = chunks(rest, 0, <<>>)
    raw = :zlib.uncompress(idat)
    rows = for y <- 0..(w - 1), do: binary_part(raw, y * (w + 1) + 1, w)
    nmod = div(w, scale) - 2 * border

    for y <- 0..(nmod - 1) do
      row = Enum.at(rows, (border + y) * scale + div(scale, 2))
      for x <- 0..(nmod - 1), do: :binary.at(row, (border + x) * scale + div(scale, 2)) < 128
    end
  end

  defp chunks(<<>>, w, idat), do: {w, idat}

  defp chunks(<<len::32, kind::binary-size(4), body::binary-size(len), crc::32, rest::binary>>, w, idat) do
    if crc != :erlang.crc32(kind <> body), do: throw({:assert, "bad CRC"})

    case kind do
      "IHDR" ->
        <<w2::32, h::32, 8, 0, _::binary>> = body
        if w2 != h, do: throw({:assert, "not square"})
        chunks(rest, w2, idat)

      "IDAT" ->
        chunks(rest, w, idat <> body)

      _ ->
        chunks(rest, w, idat)
    end
  end
end
