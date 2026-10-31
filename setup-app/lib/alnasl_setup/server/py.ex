defmodule AlnaslSetup.Server.Py do
  @moduledoc """
  The few Python semantics the setup server's answers depend on, so that they come out as the Python
  server gave them: int() and str() of what a JSON body holds, truthiness, round(x, n), strftime with the
  local offset, parse_qs, urlsplit's checks, os.path.normpath, and the ipaddress module's IPv4 rules
  (with its error texts, which reach the page as the answer to a bad request).

  Also the server's test seams (all unset on the box): `:later` (`:inline` runs a delayed action at
  once), `:wait_scale` (multiplies the Wi-Fi waits), `:modules` (stand-ins for the other parts).
  """
  alias AlnaslSetup.Sys

  # ------------------------------------------------------------------------------------- seams --

  @mods %{
    bootlog: AlnaslSetup.Bootlog,
    bootlog_follower: AlnaslSetup.Bootlog.Follower,
    hotspot: AlnaslSetup.Hotspot,
    arkab_live: AlnaslSetup.ArkabLive,
    system_update: AlnaslSetup.SystemUpdate
  }

  @doc "The module that does `key` (another part of the release; a stand-in in the tests)."
  def mod(key), do: Map.get(Application.get_env(:alnasl_setup, :modules, %{}), key, Map.fetch!(@mods, key))

  def env(key, default), do: Application.get_env(:alnasl_setup, key, default)

  @doc "Python's later(delay, fn): run it after a delay in its own process, so the HTTP answer goes out first."
  def later(delay, fun) when is_function(fun, 0) do
    case env(:later, :spawn) do
      :inline ->
        fun.()
        :ok

      _ ->
        spawn(fn ->
          Process.sleep(round(delay * 1000))
          fun.()
        end)

        :ok
    end
  end

  @doc "time.sleep, scaled by the tests' `:wait_scale`."
  def nap(seconds), do: Process.sleep(round(seconds * 1000 * env(:wait_scale, 1)))

  def log(msg), do: Sys.log("alnasl-setup", msg)

  # ---------------------------------------------------------------------------------- builtins --

  @doc "Python truthiness of a JSON value."
  def truthy?(v), do: v not in [nil, false, 0, +0.0, -0.0, "", [], %{}]

  @doc "int(v): `{:ok, i}`, `{:value_error, message}` or `:type_error`."
  def int(v) when is_integer(v), do: {:ok, v}
  def int(true), do: {:ok, 1}
  def int(false), do: {:ok, 0}
  def int(v) when is_float(v), do: {:ok, trunc(v)}

  def int(v) when is_binary(v) do
    s = String.trim(v)

    if Regex.match?(~r/^[+-]?\d+(_\d+)*$/, s),
      do: {:ok, s |> String.replace("_", "") |> String.to_integer()},
      else: {:value_error, "invalid literal for int() with base 10: " <> repr(v)}
  end

  def int(_), do: :type_error

  @doc "int(v) that raises like Python: ArgumentError for a ValueError (a 400), RuntimeError otherwise."
  def int!(v) do
    case int(v) do
      {:ok, i} -> i
      {:value_error, m} -> raise ArgumentError, m
      :type_error -> raise "int() argument must be a string or a number"
    end
  end

  @doc "float(v), or nil when Python's float() would raise."
  def float(v) when is_float(v), do: v
  def float(v) when is_integer(v), do: v * 1.0
  def float(true), do: 1.0
  def float(false), do: 0.0

  def float(v) when is_binary(v) do
    s = String.trim(v)

    s = if String.starts_with?(s, "."), do: "0" <> s, else: s
    s = String.replace(s, ~r/^([+-])\./, "\\g{1}0.")

    case Float.parse(s) do
      {f, ""} ->
        f

      _ ->
        case Integer.parse(s) do
          {i, ""} -> i * 1.0
          _ -> nil
        end
    end
  end

  def float(_), do: nil

  @doc "str(v) of a JSON value."
  def str(v) when is_binary(v), do: v
  def str(nil), do: "None"
  def str(true), do: "True"
  def str(false), do: "False"
  def str(v) when is_integer(v), do: Integer.to_string(v)
  def str(v) when is_float(v), do: AlnaslSetup.Json.encode(v)
  def str(v), do: AlnaslSetup.Json.encode(v)

  @doc "str(v or \"\")."
  def str_or_empty(v), do: if(truthy?(v), do: str(v), else: "")

  @doc "repr() of a string, as Python quotes it (single quotes unless the text has one)."
  def repr(s) do
    if String.contains?(s, "'") and not String.contains?(s, "\""),
      do: "\"" <> s <> "\"",
      else: "'" <> String.replace(String.replace(s, "\\", "\\\\"), "'", "\\'") <> "'"
  end

  @doc "len() of a str: code points, not graphemes."
  def len(s), do: length(String.codepoints(s))

  @doc """
  round(x, n) as Python does it: on the exact binary value of the float, a tie to the even digit
  (round(45.25, 1) == 45.2, round(2.675, 2) == 2.67).
  """
  def round(x, n) when is_integer(x), do: round(x * 1.0, n)

  def round(x, n) when is_float(x) do
    <<sign::1, exp::11, mant::52>> = <<x::float>>
    {m, e} = if exp == 0, do: {mant, -1074}, else: {mant + Bitwise.bsl(1, 52), exp - 1075}
    scale = Integer.pow(10, n)
    # |x| * 10^n = m * scale * 2^e
    num = m * scale

    q =
      if e >= 0 do
        Bitwise.bsl(num, e)
      else
        d = Bitwise.bsl(1, -e)
        {q, r} = {div(num, d), rem(num, d)}

        cond do
          2 * r > d -> q + 1
          2 * r < d -> q
          rem(q, 2) == 1 -> q + 1
          true -> q
        end
      end

    v = q / scale
    if sign == 1, do: -v, else: v
  end

  # ------------------------------------------------------------------------------------- time --

  @doc "time.strftime(fmt) in local time; %Y %m %d %H %M %S %z only."
  def strftime(fmt) do
    utc = :calendar.universal_time()
    local = :calendar.universal_time_to_local_time(utc)
    {{y, mo, d}, {h, mi, s}} = local
    off = :calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc)
    p = &String.pad_leading(Integer.to_string(&1), 2, "0")
    z = if(off < 0, do: "-", else: "+") <> p.(div(abs(off), 3600)) <> p.(rem(div(abs(off), 60), 60))

    fmt
    |> String.replace("%Y", Integer.to_string(y))
    |> String.replace("%m", p.(mo))
    |> String.replace("%d", p.(d))
    |> String.replace("%H", p.(h))
    |> String.replace("%M", p.(mi))
    |> String.replace("%S", p.(s))
    |> String.replace("%z", z)
  end

  def monotonic, do: System.monotonic_time(:microsecond) / 1_000_000

  # -------------------------------------------------------------------------------------- urls --

  @doc "parse_qs: name -> [values], blank values dropped (Python's default)."
  def parse_qs(q) do
    (q || "")
    |> URI.query_decoder()
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.update(acc, k, [v], &(&1 ++ [v])) end)
  rescue
    _ -> %{}
  end

  @doc "The first value of a query parameter, or `default`."
  def qs_first(q, key, default) do
    case parse_qs(q)[key] do
      [v | _] -> v
      _ -> default
    end
  end

  @doc """
  The parts of urllib.parse.urlsplit the checks use: `%{scheme, hostname, username, password, fragment,
  port}`; port is `{:ok, n | nil}` or `:error` (Python raises when the port is read).
  """
  def urlsplit(url) do
    {scheme, rest} =
      case Regex.run(~r/^([A-Za-z][A-Za-z0-9+\-.]*):(.*)$/s, url) do
        [_, s, r] -> {String.downcase(s), r}
        _ -> {"", url}
      end

    {rest, fragment} =
      case String.split(rest, "#", parts: 2) do
        [r, f] -> {r, f}
        [r] -> {r, ""}
      end

    netloc =
      case rest do
        "//" <> r -> r |> String.split(["/", "?"], parts: 2) |> hd()
        _ -> ""
      end

    {userinfo, hostport} =
      case :binary.matches(netloc, "@") do
        [] ->
          {nil, netloc}

        ms ->
          {pos, _} = List.last(ms)
          {binary_part(netloc, 0, pos), binary_part(netloc, pos + 1, byte_size(netloc) - pos - 1)}
      end

    {username, password} =
      case userinfo do
        nil ->
          {nil, nil}

        u ->
          case String.split(u, ":", parts: 2) do
            [a, b] -> {a, b}
            [a] -> {a, nil}
          end
      end

    {host, port_s} =
      case Regex.run(~r/^\[([^\]]*)\](?::(.*))?$/, hostport) do
        [_, h] ->
          {h, nil}

        [_, h, p] ->
          {h, p}

        nil ->
          case String.split(hostport, ":", parts: 2) do
            [h, p] -> {h, p}
            [h] -> {h, nil}
          end
      end

    port =
      cond do
        port_s in [nil, ""] -> {:ok, nil}
        Regex.match?(~r/^\d+$/, port_s) and String.to_integer(port_s) <= 65_535 -> {:ok, String.to_integer(port_s)}
        true -> :error
      end

    %{
      scheme: scheme,
      hostname: if(host == "", do: nil, else: String.downcase(host)),
      username: username,
      password: password,
      fragment: fragment,
      port: port
    }
  end

  @doc "os.path.normpath of an absolute POSIX path (lexical; a leading // stays, as in Python)."
  def normpath(p) do
    lead = if String.starts_with?(p, "//") and not String.starts_with?(p, "///"), do: "//", else: "/"

    segs =
      p
      |> String.split("/")
      |> Enum.reduce([], fn
        "", acc -> acc
        ".", acc -> acc
        "..", [] -> []
        "..", [_ | acc] -> acc
        s, acc -> [s | acc]
      end)
      |> Enum.reverse()

    lead <> Enum.join(segs, "/")
  end

  # -------------------------------------------------------------------------------- ipaddress --

  @doc "An IPv4 address as an integer, or nil (Python's strict rules: four parts, no leading zeros)."
  def ipv4(s) when is_binary(s) do
    parts = String.split(s, ".")

    if length(parts) == 4 and Enum.all?(parts, &Regex.match?(~r/^(0|[1-9]\d{0,2})$/, &1)) do
      ns = Enum.map(parts, &String.to_integer/1)
      if Enum.all?(ns, &(&1 <= 255)), do: Enum.reduce(ns, 0, &(&2 * 256 + &1)), else: nil
    end
  end

  def ipv4(_), do: nil

  def ipv6?(s) when is_binary(s), do: match?({:ok, _}, :inet.parse_ipv6strict_address(String.to_charlist(s)))
  def ipv6?(_), do: false

  def ipv4_string(n) do
    Enum.map_join([24, 16, 8, 0], ".", fn sh -> Integer.to_string(Bitwise.band(Bitwise.bsr(n, sh), 255)) end)
  end

  @doc """
  ipaddress.ip_address(s): `{4, int}` or `{6, s}`; raises ArgumentError with Python's text.
  """
  def ip_address(s) do
    cond do
      n = ipv4(s) -> {4, n}
      ipv6?(s) -> {6, s}
      true -> raise ArgumentError, "#{repr(str(s))} does not appear to be an IPv4 or IPv6 address"
    end
  end

  @doc """
  ipaddress.ip_interface(s): `{4, ip, prefixlen}` or `{6, s, prefixlen}`; raises ArgumentError with
  Python's text. The prefix is a length or a netmask (or a host mask), as Python allows.
  """
  def ip_interface(s) when is_binary(s) do
    bad = fn -> raise ArgumentError, "#{repr(s)} does not appear to be an IPv4 or IPv6 interface" end

    {a, pfx} =
      case String.split(s, "/") do
        [a] -> {a, nil}
        [a, p] -> {a, p}
        _ -> bad.()
      end

    cond do
      ip = ipv4(a) ->
        case v4_prefix(pfx) do
          nil -> bad.()
          len -> {4, ip, len}
        end

      ipv6?(a) ->
        case pfx do
          nil ->
            {6, a, 128}

          p ->
            if Regex.match?(~r/^\d{1,3}$/, p) and String.to_integer(p) <= 128,
              do: {6, a, String.to_integer(p)},
              else: bad.()
        end

      true ->
        bad.()
    end
  end

  def ip_interface(s), do: raise(ArgumentError, "#{repr(str(s))} does not appear to be an IPv4 or IPv6 interface")

  defp v4_prefix(nil), do: 32

  defp v4_prefix(p) do
    cond do
      Regex.match?(~r/^\d+$/, p) ->
        n = String.to_integer(p)
        if n <= 32, do: n

      m = ipv4(p) ->
        bits = m |> Integer.to_string(2) |> String.pad_leading(32, "0")

        cond do
          Regex.match?(~r/^1*0*$/, bits) -> bits |> String.graphemes() |> Enum.count(&(&1 == "1"))
          Regex.match?(~r/^0*1*$/, bits) -> bits |> String.graphemes() |> Enum.count(&(&1 == "0"))
          true -> nil
        end

      true ->
        nil
    end
  end

  @doc "Is the IPv4 address (integer) inside network/prefix?"
  def in_net?(ip, net, prefix) do
    mask = if prefix == 0, do: 0, else: Bitwise.bsl(Bitwise.bsl(1, prefix) - 1, 32 - prefix)
    Bitwise.band(ip, mask) == Bitwise.band(net, mask)
  end
end
