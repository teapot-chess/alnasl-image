defmodule AlnaslSetup.QRTest do
  # Port of scripts/test-qr.py: the encoder is checked by DECODING what it draws, with a decoder that
  # shares no code with it (test/support/qr_decoder.ex).
  use ExUnit.Case, async: true
  alias AlnaslSetup.QR
  alias AlnaslSetup.Test.QRDecoder

  defp decode!(matrix) do
    assert {:ok, res} = QRDecoder.decode(matrix)
    res
  end

  test "Reed-Solomon: the HELLO WORLD 1-M example's ten ECC codewords" do
    hw = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
    assert QR.rs_remainder(hw, QR.rs_divisor(10)) == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]
  end

  test "format bits: M with mask 0 is 101010000010010, and every mask matches the BCH code" do
    assert QR.format_bits(0) == 0b101010000010010
    for m <- 0..7, do: assert(QR.format_bits(m) == QRDecoder.bch_format(m))
  end

  test "version bits of version 7: 000111110010010100" do
    assert QR.version_bits(7) == 0b000111110010010100
  end

  test "alignment centres match the standard's table, versions 1-10" do
    for v <- 1..10, do: assert(QR.alignment_positions(v) == QRDecoder.align()[v])
  end

  describe "symbols decode" do
    test "1 to 213 bytes, versions 1-10, chosen and fixed masks" do
      rnd = fn len, seed ->
        {bytes, _} =
          Enum.reduce(1..len, {<<>>, :rand.seed_s(:exsss, seed)}, fn _, {acc, st} ->
            {b, st} = :rand.uniform_s(256, st)
            {acc <> <<b - 1>>, st}
          end)

        bytes
      end

      lens = [1, 13, 14, 26, 27, 41, 42, 61, 62, 83, 84, 105, 106, 121, 151, 152, 179, 180, 211, 213]

      samples =
        ["A", "hello", "WIFI:T:WPA;S:Alnasl-setup-4F2A;P:Kp7xR3mQ2w;;"] ++
          Enum.map(lens, &rnd.(&1, 1729 + &1))

      versions =
        for s <- samples, mask <- [nil, 0, 3, 7] do
          {got, ver, m} = decode!(QR.encode(s, mask))
          assert got == s, "#{byte_size(s)} bytes, mask #{inspect(mask)}"
          if mask, do: assert(m == mask)
          ver
        end

      assert versions |> Enum.uniq() |> Enum.sort() == Enum.to_list(1..10)
    end

    test "214 bytes are refused (more than version 10-M holds)" do
      assert_raise ArgumentError, fn -> QR.encode(String.duplicate("x", 214)) end
    end
  end

  describe "the Wi-Fi payload" do
    test "plain" do
      assert QR.wifi_payload("Alnasl-setup-4F2A", "Kp7xR3mQ2w") == "WIFI:T:WPA;S:Alnasl-setup-4F2A;P:Kp7xR3mQ2w;;"
    end

    test "escapes \\ ; , : and \"" do
      assert QR.wifi_payload("a;b", "p\\a:s,s\"w;") == "WIFI:T:WPA;S:a\\;b;P:p\\\\a\\:s\\,s\\\"w\\;;;"
    end

    test "the longest possible payload (63 escaped characters) fits" do
      assert byte_size(QR.wifi_payload("Alnasl-setup-FFFF", String.duplicate(";", 63))) <= 213
      assert {:ok, _} = QRDecoder.decode(QR.encode(QR.wifi_payload("Alnasl-setup-FFFF", String.duplicate(";", 63))))
    end
  end

  describe "the PNG" do
    test "is read back, pixel by pixel, to the payload" do
      payload = QR.wifi_payload("Alnasl-setup-4F2A", "Kp7xR3mQ2w")
      blob = QR.wifi_png("Alnasl-setup-4F2A", "Kp7xR3mQ2w")
      assert binary_part(blob, 0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>
      {got, _ver, _m} = decode!(QRDecoder.png_matrix(blob, 10, 4))
      assert got == payload
    end

    test "the same input gives the same bytes, compressed at level 9 like Python's zlib.compress(..., 9)" do
      a = QR.wifi_png("Alnasl-setup-ABCD", "Kp7xR3mQ2w")
      assert a == QR.wifi_png("Alnasl-setup-ABCD", "Kp7xR3mQ2w")
      refute a == QR.wifi_png("Alnasl-setup-ABCE", "Kp7xR3mQ2w")
      # 8 signature bytes + the 25-byte IHDR chunk, then the IDAT chunk.
      <<_::binary-size(33), idat::binary>> = a
      assert <<_len::32, "IDAT", 0x78, 0xDA, _::binary>> = idat
    end

    test "png/3 honours scale and border" do
      m = QR.encode("A")
      blob = QR.png(m, 4, 2)
      {got, 1, _} = decode!(QRDecoder.png_matrix(blob, 4, 2))
      assert got == "A"
    end
  end
end
