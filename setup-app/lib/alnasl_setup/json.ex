defmodule AlnaslSetup.Json do
  @moduledoc """
  JSON the way the Python programs wrote it (json.dumps with its defaults), so that files on the box and
  answers to the pages read exactly as before: `", "` and `": "` as separators, non-ASCII as `\\uXXXX`
  (UTF-16 surrogate pairs above the BMP). Map keys come out sorted (Python kept insertion order; no reader
  of these files or answers depends on the order).

  Decoding is Elixir's own `JSON` module.
  """

  def decode(bin) when is_binary(bin) do
    case JSON.decode(bin) do
      {:ok, v} -> {:ok, v}
      {:error, _} = e -> e
    end
  end

  def decode(_), do: {:error, :not_binary}

  @doc "The value, or nil when the text is not JSON."
  def decode_or_nil(bin) do
    case decode(bin) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  def encode(v), do: IO.iodata_to_binary(enc(v))

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(a) when is_atom(a), do: str(Atom.to_string(a))
  defp enc(i) when is_integer(i), do: Integer.to_string(i)
  defp enc(f) when is_float(f), do: float(f)
  defp enc(s) when is_binary(s), do: str(s)
  defp enc(%{} = m) when map_size(m) == 0, do: "{}"

  defp enc(%{} = m) do
    items =
      m
      |> Enum.map(fn {k, v} -> {key(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [str(k), ": ", enc(v)] end)

    ["{", Enum.intersperse(items, ", "), "}"]
  end

  defp enc([]), do: "[]"
  defp enc(l) when is_list(l), do: ["[", Enum.intersperse(Enum.map(l, &enc/1), ", "), "]"]
  defp enc(t) when is_tuple(t), do: enc(Tuple.to_list(t))

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_integer(k), do: Integer.to_string(k)

  # Python's repr of a float: shortest round-trip, "1.0" not "1", "1e+16" style exponents.
  defp float(f) do
    s = :erlang.float_to_binary(f, [:short])

    cond do
      String.contains?(s, "e") ->
        [m, e] = String.split(s, "e")
        m = String.replace_suffix(m, ".0", "")
        {sign, digits} = if String.starts_with?(e, "-"), do: {"-", String.trim_leading(e, "-")}, else: {"+", e}
        m <> "e" <> sign <> String.pad_leading(digits, 2, "0")

      true ->
        s
    end
  end

  defp str(s) do
    s = scrub(s)
    ["\"", esc(s, []), "\""]
  end

  defp esc(<<>>, acc), do: Enum.reverse(acc)
  defp esc(<<"\"", r::binary>>, acc), do: esc(r, ["\\\"" | acc])
  defp esc(<<"\\", r::binary>>, acc), do: esc(r, ["\\\\" | acc])
  defp esc(<<"\n", r::binary>>, acc), do: esc(r, ["\\n" | acc])
  defp esc(<<"\r", r::binary>>, acc), do: esc(r, ["\\r" | acc])
  defp esc(<<"\t", r::binary>>, acc), do: esc(r, ["\\t" | acc])
  defp esc(<<"\b", r::binary>>, acc), do: esc(r, ["\\b" | acc])
  defp esc(<<"\f", r::binary>>, acc), do: esc(r, ["\\f" | acc])
  defp esc(<<c, r::binary>>, acc) when c < 0x20, do: esc(r, [u4(c) | acc])
  defp esc(<<c, r::binary>>, acc) when c < 0x80, do: esc(r, [<<c>> | acc])

  defp esc(<<c::utf8, r::binary>>, acc) when c > 0xFFFF do
    v = c - 0x10000
    esc(r, [[u4(0xD800 + Bitwise.bsr(v, 10)), u4(0xDC00 + Bitwise.band(v, 0x3FF))] | acc])
  end

  defp esc(<<c::utf8, r::binary>>, acc), do: esc(r, [u4(c) | acc])

  defp u4(c), do: "\\u" <> String.downcase(String.pad_leading(Integer.to_string(c, 16), 4, "0"))

  @doc "Invalid UTF-8 becomes U+FFFD (Python decoded command output with errors=\"replace\")."
  def scrub(s) do
    if String.valid?(s), do: s, else: do_scrub(s, [])
  end

  defp do_scrub(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp do_scrub(<<c::utf8, r::binary>>, acc), do: do_scrub(r, [<<c::utf8>> | acc])
  defp do_scrub(<<_, r::binary>>, acc), do: do_scrub(r, ["�" | acc])
end
