defmodule AlnaslSetup.Portal do
  @moduledoc """
  The captive portal of the setup hotspot (docs/captive-portal.md).

  Listens on 10.42.0.1:80 only, and only while the hotspot is up (alnasl-hotspot starts and stops it). It
  runs as an unprivileged dynamic user with the one capability of binding port 80, holds no secret and
  changes nothing itself: the page's few calls go to the setup server on 127.0.0.1:4041, and ONLY the
  ones in `pass_get/0` and `pass_post/0` (Wi-Fi, the box's access PIN, Arkab's join link, and reading what the page
  shows). Factory reset, updates, the role, power, diagnostics: not on the list, so not reachable from a
  phone, however it asks.

  Every phone OS finds out it is behind a portal by fetching a known URL and expecting a known answer
  (Apple: captive.apple.com/hotspot-detect.html wants "Success"; Android: /generate_204 wants a 204;
  Windows: /connecttest.txt wants "Microsoft Connect Test"; Firefox: /canonical.html). DNS on the hotspot
  answers every name with 10.42.0.1, so all of those land here, and every request that is not for
  10.42.0.1 itself gets a redirect to http://10.42.0.1/ - which is the wrong answer to each of them, and
  the wrong answer is what makes the phone show its sign-in sheet.

  Start options (all optional; the defaults are the box's, the rest is for the tests): `:id`, `:ip` (tuple),
  `:port`, `:setup` (`{host, port}` of the setup server), `:www` (the page's directory),
  `:log_fun` (`fn message -> any`, instead of the journal). Application environment `:portal_addr`,
  `:portal_port`, `:portal_setup` and `:portal_www` do the same for the release.
  """
  alias AlnaslSetup.{Http, Json, Sys}

  @addr "10.42.0.1"
  @portal "http://10.42.0.1/"
  @pass_get ["/api/portal", "/api/portal/scan"]
  @pass_post ["/api/portal/join", "/api/portal/pin", "/api/portal/arkab-join"]
  @static %{
    "/" => {"portal.html", "text/html; charset=utf-8"},
    "/index.html" => {"portal.html", "text/html; charset=utf-8"},
    "/portal.js" => {"portal.js", "text/javascript; charset=utf-8"},
    "/app.css" => {"app.css", "text/css; charset=utf-8"}
  }
  @max_body 8192

  def addr, do: @addr
  def setup_target, do: {"127.0.0.1", 4041}
  def pass_get, do: @pass_get
  def pass_post, do: @pass_post

  @doc "The portal's HTTP server as a supervisor child (id `AlnaslSetup.Portal`)."
  def child_spec(opts \\ []) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(opts \\ []) do
    ip =
      Keyword.get_lazy(opts, :ip, fn ->
        {:ok, ip} = :inet.parse_address(String.to_charlist(Application.get_env(:alnasl_setup, :portal_addr, @addr)))
        ip
      end)

    port = Keyword.get_lazy(opts, :port, fn -> Application.get_env(:alnasl_setup, :portal_port, 80) end)
    id = Keyword.get(opts, :id, __MODULE__)

    cfg = %{
      setup:
        Keyword.get_lazy(opts, :setup, fn -> Application.get_env(:alnasl_setup, :portal_setup, setup_target()) end),
      www:
        Keyword.get_lazy(opts, :www, fn ->
          Application.get_env(:alnasl_setup, :portal_www, "/usr/local/share/alnasl-setup/www")
        end),
      log: Keyword.get(opts, :log_fun, &log/1)
    }

    result =
      Http.start_link(
        id: id,
        ip: ip,
        port: port,
        handler: &handle(&1, cfg),
        server: "alnasl-portal",
        idle_timeout: 60_000,
        max_body: @max_body,
        backlog: 32,
        # method, path, status; never a query or a body
        log: fn method, target, status ->
          cfg.log.("#{method} #{target |> String.split("?") |> hd() |> String.slice(0, 80)} #{status}")
        end
      )

    with {:ok, _} <- result, do: cfg.log.("listening on #{format_ip(ip)}:#{Http.port(id)}")
    result
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()
  defp log(msg), do: Sys.log("alnasl-portal", msg)

  @doc """
  RFC 8908. Clients only believe it over HTTPS, which a box with no certificate cannot offer, so in
  practice the OS probes do the work; it costs nothing to be right where someone does look.
  """
  def captive_json, do: %{"captive" => true, "user-portal-url" => @portal}

  @doc """
  What to do with a request: `{:redirect, url}`, `{:static, file, type}`, `{:captive}`, `{:pass, path}` or
  `{:forbidden}`. Pure, for the tests.
  """
  def route(method, host, path) do
    host = String.downcase(host || "")

    cond do
      # every probe, every other site: the setup page
      host not in [@addr, @addr <> ":80"] -> {:redirect, @portal}
      method == "GET" -> route_get(path)
      method == "POST" and path in @pass_post -> {:pass, path}
      true -> {:forbidden}
    end
  end

  defp route_get(path) do
    cond do
      Map.has_key?(@static, path) -> Tuple.insert_at(Map.fetch!(@static, path), 0, :static)
      path == "/api/captive" -> {:captive}
      path in @pass_get -> {:pass, path}
      String.starts_with?(path, "/api/") -> {:forbidden}
      true -> {:redirect, @portal}
    end
  end

  # ------------------------------------------------------------- the handler ---
  defp handle(req, cfg) do
    method = if req.method == "HEAD", do: "GET", else: req.method
    what = route(method, req.headers["host"], req.path)

    try do
      answer(what, method, req, cfg)
    catch
      :throw, :setup_failed ->
        cfg.log.("#{method} #{req.path} setup server: failed")
        json(502, %{"error" => "box_busy"})
    end
  end

  defp answer({:redirect, url}, _method, _req, _cfg) do
    body = ~s(<!doctype html><title>Alnasl setup</title><a href="#{@portal}">Alnasl setup</a>)
    send_(302, body, "text/html; charset=utf-8", [{"Location", url}])
  end

  defp answer({:static, file, type}, _method, _req, cfg) do
    case File.read(Path.join(Sys.path(cfg.www), file)) do
      {:ok, data} -> send_(200, data, type)
      {:error, _} -> throw(:setup_failed)
    end
  end

  defp answer({:captive}, _method, _req, _cfg), do: send_(200, Json.encode(captive_json()), "application/captive+json")

  defp answer({:pass, path}, method, req, cfg) do
    cond do
      method == "GET" ->
        passed(setup_call("GET", path, nil, cfg))

      # Same rule as the setup server: a custom header and JSON, so no other origin can post.
      req.headers["x-alnasl-setup"] != "1" ->
        {403, base_headers(), %{"error" => "forbidden"}, :close}

      req.body == :too_large ->
        {413, base_headers(), %{"error" => "too large"}, :close}

      true ->
        passed(setup_call("POST", path, req.body, cfg))
    end
  end

  defp answer({:forbidden}, _method, _req, _cfg), do: {403, base_headers(), %{"error" => "forbidden"}, :close}

  defp passed({status, data}), do: send_(status, data, "application/json")

  defp json(status, map), do: {status, base_headers(), map}

  defp send_(status, body, ctype, extra \\ []) do
    {status, [{"Content-Type", ctype} | base_headers()] ++ extra, body}
  end

  defp base_headers, do: [{"X-Frame-Options", "DENY"}]

  # ------------------------------------------- the pass-through to the setup server ---
  # A plain request over :gen_tcp to the setup server (Host: 127.0.0.1:4041, and for a POST the custom
  # header and the JSON type); its status and body go back as they are, 200000 bytes at most.
  defp setup_call(method, path, body, cfg) do
    {host, port} = cfg.setup
    timeout = 90_000

    headers =
      ["Host: #{host}:#{port}\r\n", "Connection: close\r\n"] ++
        if(method == "POST",
          do: [
            "Content-Type: application/json\r\n",
            "X-Alnasl-Setup: 1\r\n",
            "Content-Length: #{byte_size(body)}\r\n"
          ],
          else: []
        )

    with {:ok, s} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false, packet: :http_bin], timeout) do
      try do
        with :ok <- :gen_tcp.send(s, [method, " ", path, " HTTP/1.1\r\n", headers, "\r\n", body || ""]),
             {:ok, status} <- read_status(s, timeout),
             {:ok, len} <- read_headers(s, nil, timeout),
             {:ok, data} <- read_body(s, len, timeout) do
          {status, binary_part(data, 0, min(byte_size(data), 200_000))}
        else
          _ -> throw(:setup_failed)
        end
      after
        :gen_tcp.close(s)
      end
    else
      _ -> throw(:setup_failed)
    end
  end

  defp read_status(s, t) do
    case :gen_tcp.recv(s, 0, t) do
      {:ok, {:http_response, _, status, _}} -> {:ok, status}
      _ -> :error
    end
  end

  defp read_headers(s, len, t) do
    case :gen_tcp.recv(s, 0, t) do
      {:ok, {:http_header, _, name, _, value}} ->
        len =
          if String.downcase(to_string(name)) == "content-length", do: String.to_integer(String.trim(value)), else: len

        read_headers(s, len, t)

      {:ok, :http_eoh} ->
        {:ok, len}

      _ ->
        :error
    end
  end

  defp read_body(s, len, t) do
    :inet.setopts(s, packet: :raw)

    case len do
      0 -> {:ok, ""}
      n when is_integer(n) -> with {:ok, data} <- :gen_tcp.recv(s, n, t), do: {:ok, data}
      nil -> read_to_close(s, [], t)
    end
  end

  defp read_to_close(s, acc, t) do
    case :gen_tcp.recv(s, 0, t) do
      {:ok, d} -> read_to_close(s, [acc | d], t)
      {:error, :closed} -> {:ok, IO.iodata_to_binary(acc)}
      _ -> :error
    end
  end
end
