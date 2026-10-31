defmodule AlnaslSetup.Server.Help do
  @moduledoc """
  "Get help": the diagnostics (already redacted by AlnaslSetup.Diag) are POSTed over HTTPS to the
  support address and the server answers with a six-digit code, which the person reads out. Outbound
  only: nothing listens for it and nothing comes back but that answer. Contract: Alnasl docs/support.md.

  HTTPS with the system's CA store and the host name checked; never a redirect (a redirect could move
  the file to plain http or elsewhere). The tests send to a plain-HTTP server on loopback through the
  test-only `:help_url` setting.
  """
  alias AlnaslSetup.{Diag, Json}
  alias AlnaslSetup.Server.{Box, Py}

  @default_url "https://alnasl.zerotwo.cloud/support/upload"
  # the server refuses more than 2 MiB
  @max_bytes 2_000_000
  @timeout 25

  def default_url, do: @default_url

  @doc "The upload address: https only, a host, no credentials, no spaces. Raises ArgumentError."
  def valid_support_url(url) do
    url = String.trim(url || "")

    cond do
      url == "" ->
        ""

      Py.len(url) > 300 or Regex.match?(~r/[\s\x00-\x1f\x7f]/u, url) ->
        raise ArgumentError, "bad_url"

      true ->
        u = Py.urlsplit(url)

        if u.scheme != "https" or not Py.truthy?(u.hostname) or Py.truthy?(u.username) or Py.truthy?(u.password) or
             Py.truthy?(u.fragment) or u.port == :error,
           do: raise(ArgumentError, "bad_url")

        url
    end
  end

  def support_url do
    case Box.get_state()["support_url"] do
      u when is_binary(u) or is_nil(u) ->
        try do
          case valid_support_url(u) do
            "" -> @default_url
            v -> v
          end
        rescue
          ArgumentError -> @default_url
        end

      _ ->
        @default_url
    end
  end

  @doc "The last code, only while it is still valid."
  def last do
    with %{} = h <- Box.get_state()["help_last"] || %{},
         {:ok, exp} <- parse_iso(Py.str(Map.get(h, "expires_at", ""))),
         true <- Py.truthy?(h["code"]),
         :gt <- DateTime.compare(exp, DateTime.utc_now()) do
      %{"code" => h["code"], "expires_at" => h["expires_at"]}
    else
      _ -> nil
    end
  end

  # datetime.fromisoformat, with Z as UTC and no offset meaning UTC
  defp parse_iso(s) do
    s = String.replace(s, "Z", "+00:00")

    case DateTime.from_iso8601(s) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(s) do
          {:ok, n} ->
            {:ok, DateTime.from_naive!(n, "Etc/UTC")}

          _ ->
            case Date.from_iso8601(s) do
              {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00], "Etc/UTC")}
              _ -> :error
            end
        end
    end
  end

  def status, do: %{"url" => support_url(), "default_url" => @default_url, "last" => last()}

  def set_url(url) do
    Box.set_state(support_url: valid_support_url(url))
    status()
  end

  defp headers do
    s = Box.sysinfo()
    box = Enum.find([s["serial"], s["hostname"]], &(&1 != "")) || "unknown"

    [
      {"x-alnasl-box", String.slice(box, 0, 100)},
      {"x-alnasl-version", String.slice("#{s["alnasl"]}/#{s["image"]}", 0, 50)},
      {"x-alnasl-mode", String.slice(Box.running_role(), 0, 50)}
    ]
  end

  @doc "The report, cut to the limit on a character boundary (the top is kept: verdict and sections; the journals come last)."
  def cut(text) do
    if byte_size(text) > @max_bytes, do: valid_prefix(binary_part(text, 0, @max_bytes)), else: text
  end

  defp valid_prefix(b) do
    if String.valid?(b), do: b, else: valid_prefix(binary_part(b, 0, byte_size(b) - 1))
  end

  defp body do
    Diag.report_text(Box.diag_info(), Diag.journals(), Box.system_header()) |> Json.scrub() |> cut()
  end

  @doc """
  Build, send, answer `%{"ok" => true, code, expires_at}` or `%{"ok" => false, "error" => key}`. Keys:
  no_internet, rate_limited, support_off, too_large, rejected, server_error.
  """
  def send_report do
    url = Py.env(:help_url, nil) || support_url()
    data = body()
    hdrs = Enum.map([{"user-agent", "alnasl-box-help"} | headers()], fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    http_opts =
      [timeout: @timeout * 1000, connect_timeout: @timeout * 1000, autoredirect: false] ++
        if(String.starts_with?(url, "https:"), do: [ssl: ssl_opts()], else: [])

    case :httpc.request(:post, {to_charlist(url), hdrs, ~c"text/plain; charset=utf-8", data}, http_opts,
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _h, body}} when status in 200..299 ->
        answer(status, binary_part(body, 0, min(byte_size(body), 4096)))

      {:ok, {{_, status, _}, _h, _body}} ->
        Py.log("help upload refused: #{status}")

        key =
          Map.get(
            %{404 => "support_off", 413 => "too_large", 429 => "rate_limited", 400 => "rejected", 415 => "rejected"},
            status,
            "server_error"
          )

        %{"ok" => false, "error" => key, "status" => status}

      {:error, reason} ->
        # DNS, no route, timeout, TLS
        Py.log("help upload failed: #{failure_name(reason)}")
        %{"ok" => false, "error" => "no_internet"}
    end
  end

  defp failure_name(:timeout), do: "TimeoutError"
  defp failure_name({:failed_connect, _}), do: "URLError"
  defp failure_name(_), do: "URLError"

  defp answer(status, body) do
    with {:ok, %{"code" => c, "expires_at" => e}} <- Json.decode(body),
         code = Py.str(c),
         exp = Py.str(e),
         true <- status == 201 and Regex.match?(~r/\A\d{6}\z/, code) do
      Box.set_state(help_last: %{"code" => code, "expires_at" => exp, "sent_at" => Py.strftime("%Y-%m-%d %H:%M:%S %z")})
      Py.log("help upload accepted")
      %{"ok" => true, "code" => code, "expires_at" => exp}
    else
      _ ->
        Py.log("help upload: unexpected answer, status #{status}")
        %{"ok" => false, "error" => "server_error", "status" => status}
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
