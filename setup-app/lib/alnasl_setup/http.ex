defmodule AlnaslSetup.Http do
  @moduledoc """
  A small HTTP/1.1 server on `:gen_tcp`, enough for the setup server (127.0.0.1:4041) and the captive
  portal (10.42.0.1:80): request line and headers through the VM's own HTTP packet parser, a body only
  with a Content-Length, keep-alive, one process per connection.

  The handler is `fn request -> response end`:

      request  = %{method: "GET", target: "/api/x?y=1", path: "/api/x", query: "y=1",
                   headers: %{"host" => "..."}, body: binary | :too_large}
      response = {status, headers :: [{name, value}], body :: iodata | map | {:json, term}}
               | {status, headers, body, :close}

  A map or `{:json, term}` body is sent as JSON (`AlnaslSetup.Json`), any other as the bytes it is. A body longer than `:max_body` is never read:
  the handler sees `:too_large` and the connection closes after the answer. HEAD gets the headers of the
  GET answer and no body. Every answer has Content-Length and Cache-Control (default no-store).
  """
  require Logger

  @reasons %{
    200 => "OK",
    201 => "Created",
    204 => "No Content",
    302 => "Found",
    400 => "Bad Request",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    413 => "Request Entity Too Large",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway"
  }

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc """
  Options: `:ip` (tuple), `:port`, `:handler`, `:server` (Server header), `:idle_timeout` (ms),
  `:max_body` (bytes), `:backlog`, `:log` (fn method, path, status -> any).
  """
  def start_link(opts) do
    parent = self()

    pid =
      spawn_link(fn ->
        listen = [
          :binary,
          active: false,
          reuseaddr: true,
          ip: Keyword.fetch!(opts, :ip),
          backlog: Keyword.get(opts, :backlog, 64),
          packet: :http_bin,
          packet_size: 16_384
        ]

        case :gen_tcp.listen(Keyword.fetch!(opts, :port), listen) do
          {:ok, ls} ->
            send(parent, {self(), :listening, :inet.port(ls)})
            accept_loop(ls, opts)

          {:error, reason} ->
            send(parent, {self(), :failed, reason})
        end
      end)

    receive do
      {^pid, :listening, {:ok, port}} ->
        :persistent_term.put({__MODULE__, Keyword.get(opts, :id, __MODULE__)}, port)
        {:ok, pid}

      {^pid, :failed, reason} ->
        {:error, reason}
    after
      10_000 -> {:error, :timeout}
    end
  end

  @doc "The port the server with this `:id` listens on (tests start them on port 0)."
  def port(id \\ __MODULE__), do: :persistent_term.get({__MODULE__, id}, nil)

  defp accept_loop(ls, opts) do
    case :gen_tcp.accept(ls) do
      {:ok, sock} ->
        pid = spawn(fn -> receive(do: (:go -> conn_loop(sock, opts))) end)
        :ok = :gen_tcp.controlling_process(sock, pid)
        send(pid, :go)
        accept_loop(ls, opts)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept_loop(ls, opts)
    end
  end

  defp conn_loop(sock, opts) do
    idle = Keyword.get(opts, :idle_timeout, 120_000)

    case read_request(sock, idle, Keyword.get(opts, :max_body, 1_000_000)) do
      {:ok, req, keep?} ->
        {status, headers, body, close?} =
          try do
            normalize(Keyword.fetch!(opts, :handler).(req))
          rescue
            e ->
              Logger.error("handler: " <> Exception.message(e))
              {500, [], %{"error" => "internal error"}, false}
          end

        close? = close? or not keep? or req.body == :too_large
        send_response(sock, req.method, status, headers, body, close?, opts)
        if log = opts[:log], do: log.(req.method, req.target, status)
        if close?, do: :gen_tcp.close(sock), else: conn_loop(sock, opts)

      {:bad, _} ->
        send_response(sock, "GET", 400, [], %{"error" => "bad request"}, true, opts)
        :gen_tcp.close(sock)

      :closed ->
        :gen_tcp.close(sock)
    end
  end

  defp normalize({s, h, b}), do: {s, h, b, false}
  defp normalize({s, h, b, :close}), do: {s, h, b, true}

  defp read_request(sock, idle, max_body) do
    :inet.setopts(sock, packet: :http_bin)

    case :gen_tcp.recv(sock, 0, idle) do
      {:ok, {:http_request, method, uri, version}} ->
        with {:ok, headers} <- read_headers(sock, %{}, 0) do
          target = target(uri)
          {path, query} = split_target(target)
          method = if is_atom(method), do: Atom.to_string(method), else: method
          keep? = keep_alive?(version, headers)
          :inet.setopts(sock, packet: :raw)

          case read_body(sock, headers, max_body) do
            {:ok, body} ->
              {:ok, %{method: method, target: target, path: path, query: query, headers: headers, body: body}, keep?}

            other ->
              other
          end
        end

      {:ok, {:http_error, _}} ->
        {:bad, :request_line}

      {:ok, _} ->
        {:bad, :unexpected}

      {:error, _} ->
        :closed
    end
  end

  defp read_headers(_sock, _acc, n) when n > 100, do: {:bad, :too_many_headers}

  defp read_headers(sock, acc, n) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        name = name |> to_string() |> String.downcase()
        read_headers(sock, Map.put_new(acc, name, value), n + 1)

      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, {:http_error, _}} ->
        {:bad, :header}

      {:error, _} ->
        :closed
    end
  end

  defp read_body(sock, headers, max_body) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {0, ""} ->
        {:ok, ""}

      {n, ""} when n > 0 and n > max_body ->
        {:ok, :too_large}

      {n, ""} when n > 0 ->
        case :gen_tcp.recv(sock, n, 30_000) do
          {:ok, body} -> {:ok, body}
          {:error, _} -> :closed
        end

      _ ->
        {:bad, :content_length}
    end
  end

  defp target({:abs_path, p}), do: p
  defp target({:absoluteURI, _scheme, _host, _port, p}), do: p
  defp target(:*), do: "*"
  defp target({:scheme, _, p}), do: p
  defp target(p) when is_binary(p), do: p
  defp target(_), do: "/"

  defp split_target(t) do
    case String.split(t, "?", parts: 2) do
      [p, q] -> {p, q}
      [p] -> {p, ""}
    end
  end

  defp keep_alive?({1, 1}, h), do: String.downcase(Map.get(h, "connection", "")) != "close"
  defp keep_alive?(_, h), do: String.downcase(Map.get(h, "connection", "")) == "keep-alive"

  defp send_response(sock, method, status, headers, body, close?, opts) do
    {body, ctype} =
      case body do
        %{} -> {AlnaslSetup.Json.encode(body), "application/json"}
        {:json, v} -> {AlnaslSetup.Json.encode(v), "application/json"}
        _ -> {IO.iodata_to_binary(body), nil}
      end

    names = Enum.map(headers, fn {k, _} -> String.downcase(k) end)

    base =
      [{"Server", Keyword.get(opts, :server, "alnasl-setup")}, {"Date", http_date()}] ++
        if("content-type" in names or ctype == nil, do: [], else: [{"Content-Type", ctype}]) ++
        [{"Content-Length", Integer.to_string(byte_size(body))}] ++
        if("cache-control" in names, do: [], else: [{"Cache-Control", "no-store"}]) ++
        headers ++
        if(close? and "connection" not in names, do: [{"Connection", "close"}], else: [])

    head = [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      Map.get(@reasons, status, "Unknown"),
      "\r\n",
      Enum.map(base, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "\r\n"
    ]

    :gen_tcp.send(sock, if(method == "HEAD", do: head, else: [head, body]))
  end

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  def http_date(dt \\ DateTime.utc_now()) do
    day = Enum.at(@days, Date.day_of_week(dt) - 1)
    mon = Enum.at(@months, dt.month - 1)
    p = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "#{day}, #{p.(dt.day)} #{mon} #{dt.year} #{p.(dt.hour)}:#{p.(dt.minute)}:#{p.(dt.second)} GMT"
  end
end
