defmodule AlnaslSetup.Server.Printers do
  @moduledoc """
  Settings > Printers, on a polis box (docs/v7-plan.md, "Polis on the box"). CUPS from Photon, without
  cups-filters or Ghostscript: a PDF goes to the printer as it is (/etc/cups/local.convs), so a printer
  that understands PDF prints (IPP Everywhere network printers, most office printers). Nothing is
  discovered: the address is typed in, or a USB printer is picked from what CUPS sees.
  """
  alias AlnaslSetup.Sys
  alias AlnaslSetup.Server.{Box, Py}

  @name_re ~r/\A[A-Za-z0-9_-]{1,32}\z/
  @addr_re ~r/\A[A-Za-z0-9.:\[\]-]{1,253}\z/
  @testpage "/run/alnasl-setup-testpage.pdf"

  defp lpstat(args) do
    case Sys.run(["lpstat" | args], timeout: 10) do
      {0, out} -> out
      _ -> ""
    end
  end

  def status do
    default =
      case Regex.run(~r/system default destination: (\S+)/, lpstat(["-d"])) do
        [_, d] -> d
        _ -> ""
      end

    uris = for [_, n, u] <- Regex.scan(~r/^device for (\S+): (\S+)$/m, lpstat(["-v"])), into: %{}, do: {n, u}

    printers =
      for [_, name, rest] <- Regex.scan(~r/^printer (\S+) (.*)$/m, lpstat(["-p"])) do
        uri = Map.get(uris, name, "")
        # what is shown of the address: scheme and host, never a user name or a query in it
        shown = Regex.replace(~r/\/\/[^@\/]*@/, uri, "//") |> String.split("?") |> hd()

        state =
          cond do
            String.contains?(rest, "disabled") -> "disabled"
            String.contains?(rest, "now printing") -> "printing"
            true -> "idle"
          end

        %{"name" => name, "uri" => shown, "default" => name == default, "state" => state}
      end

    %{"printers" => printers, "cups" => Box.unit_state("cups.service")["active"]}
  end

  def usb do
    case Sys.run(["lpinfo", "--include-schemes", "usb", "-v"], timeout: 30) do
      {0, out} -> %{"usb" => Regex.scan(~r/^direct (usb:\/\/\S+)$/m, out) |> Enum.map(&Enum.at(&1, 1)) |> Enum.take(16)}
      _ -> %{"usb" => []}
    end
  end

  defp printer_name(b, fallback) do
    n = b |> Map.get("name") |> Py.str_or_empty() |> String.trim()

    n =
      if n == "" do
        f = Regex.replace(~r/[^A-Za-z0-9_-]+/, fallback, "-") |> String.trim("-") |> String.slice(0, 32)
        if f == "", do: "printer", else: f
      else
        n
      end

    if not Regex.match?(@name_re, n), do: raise(ArgumentError, "bad_printer_name")
    n
  end

  def add(b) do
    usb = Py.str_or_empty(b["usb"])

    {name, cmd} =
      if usb != "" do
        if not String.starts_with?(usb, "usb://") or usb not in usb()["usb"],
          do: raise(ArgumentError, "bad_printer_address")

        fallback = usb |> String.slice(6..-1//1) |> String.split("?") |> hd() |> String.replace("/", "-")
        name = printer_name(b, fallback)
        {name, ["lpadmin", "-p", name, "-E", "-v", usb, "-m", "raw"]}
      else
        addr = b["address"] |> Py.str_or_empty() |> String.trim()
        if not Regex.match?(@addr_re, addr), do: raise(ArgumentError, "bad_printer_address")
        name = printer_name(b, addr)
        {name, ["lpadmin", "-p", name, "-E", "-v", "ipp://#{addr}/ipp/print", "-m", "everywhere"]}
      end

    {rc, _out} = Sys.run(cmd, timeout: 60)

    if rc != 0 do
      Py.log("lpadmin failed for #{name}")
      raise ArgumentError, "printer_not_added"
    end

    if not Enum.any?(status()["printers"], & &1["default"]), do: Sys.run(["lpadmin", "-d", name], timeout: 20)
    Py.log("printer added: #{name}")
    status()
  end

  defp known(b) do
    name = Py.str_or_empty(b["name"])

    if not Regex.match?(@name_re, name) or name not in Enum.map(status()["printers"], & &1["name"]),
      do: raise(ArgumentError, "bad_printer_name")

    name
  end

  def default(b) do
    Sys.run(["lpadmin", "-d", known(b)], timeout: 20)
    status()
  end

  def remove(b) do
    name = known(b)
    Sys.run(["lpadmin", "-x", name], timeout: 20)
    Py.log("printer removed: #{name}")
    status()
  end

  @doc "A one-page A4 PDF with two lines of Helvetica: what the printer gets is a PDF, as Polis sends."
  def test_pdf(title, line) do
    content = "BT /F1 28 Tf 72 740 Td (#{esc(title)}) Tj ET BT /F1 14 Tf 72 700 Td (#{esc(line)}) Tj ET"

    objs = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{byte_size(content)} >>\nstream\n" <> content <> "\nendstream"
    ]

    {pdf, offs} =
      objs
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {o, i}, {pdf, offs} ->
        {pdf <> "#{i} 0 obj\n" <> o <> "\nendobj\n", [byte_size(pdf) | offs]}
      end)

    xref = byte_size(pdf)
    n = length(objs) + 1

    pdf <>
      "xref\n0 #{n}\n0000000000 65535 f \n" <>
      Enum.map_join(Enum.reverse(offs), &(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n")) <>
      "trailer\n<< /Size #{n} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end

  # ASCII with "?" for anything else, then the PDF string escapes
  defp esc(t) do
    t
    |> String.to_charlist()
    |> Enum.map(fn c -> if c < 128, do: c, else: ?? end)
    |> List.to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  def test(b) do
    name = known(b)
    File.mkdir_p!(Path.dirname(Sys.path(@testpage)))

    File.write!(
      Sys.path(@testpage),
      test_pdf("Alnasl - test page", "Printer #{name}, #{Py.strftime("%Y-%m-%d %H:%M")}")
    )

    case Sys.run(["lp", "-d", name, "-t", "Alnasl test page", "-o", "media=A4", @testpage], timeout: 30) do
      {0, _} -> %{"ok" => true}
      _ -> raise ArgumentError, "printer_test_failed"
    end
  end
end
