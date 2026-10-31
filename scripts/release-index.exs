# make-release.sh's index writer: this release's entry (alnasl-system-v<version>.json) and index.json
# (an earlier index, if given, plus this entry). Replaces the python3 heredoc. Run in the Elixir image
# (make-release.sh does it with docker) or with any local elixir:
#
#   elixir release-index.exs OUT FILE TRAIN VERSION BASE SIZE SHA RAW_SIZE RAW_SHA MIN_FROM NOTES OLD_INDEX
#
# The output is what Python's json.dump(indent=1) wrote (one-space indent, ", " never, ": " after keys,
# non-ASCII as \uXXXX, a final newline), with the entry's keys in the order below, so the same inputs
# give the same bytes: sign-release.sh signs index.json byte for byte, and alnasl-system-update's
# parse_index() reads it (format 1, images[] with train, version, file, url, sig_url, size, sha256,
# raw_size, raw_sha256, min_from, released, notes).
defmodule ReleaseIndex do
  @entry_keys ~w(train version file url sig_url size sha256 raw_size raw_sha256 min_from released notes)

  # An object whose keys keep the given order: {:obj, [{key, value}]}.
  def obj(map) when is_map(map) do
    {known, rest} = Enum.split_with(map, fn {k, _} -> k in @entry_keys end)
    known = Enum.sort_by(known, fn {k, _} -> Enum.find_index(@entry_keys, &(&1 == k)) end)
    {:obj, Enum.map(known ++ Enum.sort(rest), fn {k, v} -> {k, wrap(v)} end)}
  end

  defp wrap(v) when is_map(v), do: obj(v)
  defp wrap(v) when is_list(v), do: Enum.map(v, &wrap/1)
  defp wrap(v), do: v

  # json.dumps(indent=1), ensure_ascii.
  def encode(v), do: enc(v, 0)

  defp enc({:obj, []}, _), do: "{}"

  defp enc({:obj, kvs}, lvl) do
    pad = String.duplicate(" ", lvl + 1)
    body = Enum.map_join(kvs, ",\n", fn {k, v} -> pad <> str(k) <> ": " <> enc(v, lvl + 1) end)
    "{\n" <> body <> "\n" <> String.duplicate(" ", lvl) <> "}"
  end

  defp enc([], _), do: "[]"

  defp enc(l, lvl) when is_list(l) do
    pad = String.duplicate(" ", lvl + 1)
    body = Enum.map_join(l, ",\n", fn v -> pad <> enc(v, lvl + 1) end)
    "[\n" <> body <> "\n" <> String.duplicate(" ", lvl) <> "]"
  end

  defp enc(nil, _), do: "null"
  defp enc(true, _), do: "true"
  defp enc(false, _), do: "false"
  defp enc(n, _) when is_integer(n), do: Integer.to_string(n)
  defp enc(n, _) when is_float(n), do: Float.to_string(n)
  defp enc(s, _) when is_binary(s), do: str(s)

  # The backslash is written as <<92>> so no escape sequence in this file can be misread.
  @bs <<92>>

  defp str(s) do
    <<34>> <> for(<<c::utf8 <- s>>, into: "", do: esc(c)) <> <<34>>
  end

  defp esc(34), do: @bs <> <<34>>
  defp esc(92), do: @bs <> @bs
  defp esc(10), do: @bs <> "n"
  defp esc(13), do: @bs <> "r"
  defp esc(9), do: @bs <> "t"
  defp esc(8), do: @bs <> "b"
  defp esc(12), do: @bs <> "f"
  defp esc(c) when c >= 0x20 and c <= 0x7E, do: <<c::utf8>>
  defp esc(c) when c < 0x10000, do: @bs <> "u" <> hex4(c)

  defp esc(c) do
    c = c - 0x10000
    @bs <> "u" <> hex4(0xD800 + Bitwise.bsr(c, 10)) <> @bs <> "u" <> hex4(0xDC00 + Bitwise.band(c, 0x3FF))
  end

  defp hex4(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

  def vkey(v), do: v |> String.split(".") |> Enum.map(&String.to_integer/1)

  def main([out, file, train, version, base, size, sha, raw_size, raw_sha, min_from, notes, old]) do
    {{y, m, d}, _} = :calendar.local_time()
    released = :io_lib.format("~4..0B-~2..0B-~2..0B", [y, m, d]) |> IO.iodata_to_binary()

    entry =
      obj(%{
        "train" => train,
        "version" => version,
        "file" => file,
        "url" => base <> file,
        "sig_url" => base <> file <> ".sig",
        "size" => String.to_integer(size),
        "sha256" => sha,
        "raw_size" => String.to_integer(raw_size),
        "raw_sha256" => raw_sha,
        "min_from" => if(min_from == "", do: nil, else: min_from),
        "released" => released,
        "notes" => notes |> String.codepoints() |> Enum.take(400) |> Enum.join()
      })

    File.write!(Path.join(out, "alnasl-system-v#{version}.json"), encode(entry) <> "\n")

    images =
      if old == "" do
        []
      else
        idx = JSON.decode!(File.read!(old))
        if idx["format"] != 1, do: raise("the old index has another format")
        idx["images"] |> Enum.reject(&(&1["version"] == version)) |> Enum.map(&obj/1)
      end

    images = Enum.sort_by(images ++ [entry], fn {:obj, kvs} -> vkey(List.keyfind(kvs, "version", 0) |> elem(1)) end)
    index = {:obj, [{"format", 1}, {"images", images}]}
    File.write!(Path.join(out, "index.json"), encode(index) <> "\n")

    versions = Enum.map_join(images, ", ", fn {:obj, kvs} -> List.keyfind(kvs, "version", 0) |> elem(1) end)
    IO.puts("index.json: #{length(images)} image(s): #{versions}")
  end

  def main(_) do
    IO.puts(:stderr, "usage: elixir release-index.exs OUT FILE TRAIN VERSION BASE SIZE SHA RAW_SIZE RAW_SHA MIN_FROM NOTES OLD_INDEX")
    System.halt(2)
  end
end

ReleaseIndex.main(System.argv())
