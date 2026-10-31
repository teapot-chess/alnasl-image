defmodule AlnaslSetup.ArkabLive do
  @moduledoc """
  Joins Arkab to a server from the setup page: Arkab's own page, driven over loopback.

  Arkab (0.5.x) has no API for joining; its status page does it, a Phoenix LiveView, and only for a
  visitor on the machine itself (ArkabWeb.Local: a loopback peer without proxy headers). So this is a
  very small LiveView client: it loads http://127.0.0.1:4050/, opens the page's websocket with the
  page's own CSRF token and session, joins the view and submits the "join" form with the link, exactly as
  the browser on the box's screen would. Then it reads the answers until the page says how it went.
  OTP only; a websocket client in 80 lines is not elegant, but neither is a hall box nobody can set up.

      join(link) -> {ok?, reason}   reason: "joined", "not_a_link", "used_or_expired", "unreachable",
                                    "version", "elsewhere", "not_a_server", "arkab_down",
                                    "arkab_refused", "no_answer"

  Arkab is asked in English (Accept-Language: en); the words below are its English words for each result
  (lib/arkab_web/words.ex), and the setup page says them in its own words, in its own language.

  The port is Arkab's 4050; `:arkab_port` in the application environment moves it (the tests).
  """
  import Bitwise
  alias AlnaslSetup.Json

  @host "127.0.0.1"
  @link_re ~r/\A(https?):\/\/[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?\/join\/[A-Za-z0-9_\-]{1,64}\z/
  # {Arkab's words, our reason}
  @results [
    {"Joined.", "joined"},
    {"not a join link", "not_a_link"},
    {"used up or expired", "used_or_expired"},
    {"does not answer from here", "unreachable"},
    {"another version of the link", "version"},
    {"another hall", "elsewhere"},
    {"not like a server", "not_a_server"}
  ]

  defp port, do: Application.get_env(:alnasl_setup, :arkab_port, 4050)

  @doc "Arkab's own rule (Arkab.Bridge.Join.parse/1), narrower: what a join link of a server looks like. The link, or nil."
  def valid_link(link) when is_binary(link) do
    link = String.trim(link)

    with [_, _scheme | port_part] <- Regex.run(@link_re, link),
         true <- port_ok?(port_part) do
      link
    else
      _ -> nil
    end
  end

  def valid_link(_), do: nil

  defp port_ok?([]), do: true
  defp port_ok?([""]), do: true

  defp port_ok?([":" <> digits]) do
    p = String.to_integer(digits)
    p > 0 and p < 65_536
  end

  @doc "Our reason for the first of Arkab's phrases found in `text`, or nil."
  def result_reason(text) when is_binary(text) do
    Enum.find_value(@results, fn {words, reason} -> if String.contains?(text, words), do: reason end)
  end

  # ------------------------------------------------------------- the HTTP page ---
  defp http_get(path, timeout) do
    with {:ok, s} <- :gen_tcp.connect(~c"127.0.0.1", port(), [:binary, active: false], timeout) do
      try do
        req =
          "GET #{path} HTTP/1.1\r\nHost: #{@host}:#{port()}\r\nAccept: text/html\r\nAccept-Language: en\r\nConnection: close\r\n\r\n"

        case :gen_tcp.send(s, req) do
          :ok -> read_all(s, [], 0, timeout)
          {:error, _} = e -> e
        end
      after
        :gen_tcp.close(s)
      end
    end
  end

  defp read_all(_s, acc, size, _t) when size >= 4_000_000, do: {:ok, split_response(IO.iodata_to_binary(acc))}

  defp read_all(s, acc, size, t) do
    case :gen_tcp.recv(s, 0, t) do
      {:ok, d} -> read_all(s, [acc | d], size + byte_size(d), t)
      {:error, :closed} -> {:ok, split_response(IO.iodata_to_binary(acc))}
      {:error, _} = e -> e
    end
  end

  defp split_response(data) do
    case :binary.split(data, "\r\n\r\n") do
      [head, body] -> {String.replace_invalid(head, "?"), String.replace_invalid(body)}
      [head] -> {String.replace_invalid(head, "?"), ""}
    end
  end

  defp attr(html, name) do
    case Regex.run(~r/(?<![\w-])#{Regex.escape(name)}="([^"]*)"/, html) do
      [_, v] -> v |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&")
      _ -> nil
    end
  end

  # ------------------------------------------------------------------ the join ---
  @doc "Joins Arkab to the server of `link`. `{true, \"joined\"}` or `{false, reason}`."
  def join(link, timeout \\ 45) do
    case valid_link(link) do
      nil -> {false, "not_a_link"}
      link -> do_join(link, System.monotonic_time(:millisecond) + timeout * 1000)
    end
  end

  defp do_join(link, deadline) do
    case http_get("/", 10_000) do
      {:error, _} ->
        {false, "arkab_down"}

      {:ok, {head, html}} ->
        with true <- String.starts_with?(head, "HTTP/1.1 200"),
             [_, csrf] <- Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html),
             [div] <- Regex.run(~r/<div[^>]*data-phx-main[^>]*>/, html),
             view_id when view_id not in [nil, ""] <- attr(div, "id"),
             session when session != nil <- attr(div, "data-phx-session") do
          cookies =
            ~r/^set-cookie:\s*([^;\r\n]+)/im
            |> Regex.scan(head, capture: :all_but_first)
            |> Enum.map_join("; ", &hd/1)

          websocket(link, deadline, cookies, csrf, view_id, session, attr(div, "data-phx-static"))
        else
          _ -> {false, "arkab_refused"}
        end
    end
  end

  defp websocket(link, deadline, cookies, csrf, view_id, session, static) do
    case :gen_tcp.connect(~c"127.0.0.1", port(), [:binary, active: false], 10_000) do
      {:error, _} ->
        {false, "arkab_down"}

      {:ok, s} ->
        try do
          converse(s, link, deadline, cookies, csrf, view_id, session, static)
        catch
          :throw, {:ws, reason} -> {false, reason}
        after
          :gen_tcp.close(s)
        end
    end
  end

  defp converse(s, link, deadline, cookies, csrf, view_id, session, static) do
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET /live/websocket?_csrf_token=#{URI.encode(csrf, &URI.char_unreserved?/1)}&vsn=2.0.0 HTTP/1.1\r\n" <>
        "Host: #{@host}:#{port()}\r\nOrigin: http://#{@host}:#{port()}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\nCookie: #{cookies}\r\nAccept-Language: en\r\n\r\n"

    send!(s, req)
    {hdr, rest} = read_handshake(s, "")
    [status_line | _] = String.split(hdr, "\r\n")
    unless String.contains?(status_line, " 101 "), do: throw({:ws, "arkab_refused"})

    topic = "lv:" <> view_id

    ws_send(s, 1, Json.encode(["1", "1", topic, "phx_join", join_payload(csrf, session, static)]))
    loop(s, rest, topic, link, deadline, false)
  end

  defp join_payload(csrf, session, static) do
    %{
      "url" => "http://#{@host}:#{port()}/",
      "params" => %{"_csrf_token" => csrf, "_mounts" => 0, "_mount_attempts" => 0},
      "session" => session,
      "static" => static,
      "sticky" => false
    }
  end

  defp read_handshake(s, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [hdr, rest] ->
        {hdr, rest}

      _ ->
        case :gen_tcp.recv(s, 0, 10_000) do
          {:ok, d} -> read_handshake(s, acc <> d)
          {:error, :closed} -> throw({:ws, "arkab_refused"})
          {:error, _} -> throw({:ws, "no_answer"})
        end
    end
  end

  # joined? = the page's reply to our phx_join has been seen (and the form sent)
  defp loop(s, buf, topic, link, deadline, joined?) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      {false, "no_answer"}
    else
      case ws_recv(s, buf, max(500, left)) do
        {:closed, _} ->
          {false, "no_answer"}

        {:ok, raw, buf} ->
          case Json.decode(raw) do
            {:ok, [_jr, ref, _topic, event, payload]} ->
              handle(s, buf, topic, link, deadline, joined?, ref, event, payload)

            _ ->
              loop(s, buf, topic, link, deadline, joined?)
          end
      end
    end
  end

  defp handle(s, buf, topic, link, deadline, false, ref, event, payload) do
    if ref == "1" and event == "phx_reply" do
      unless is_map(payload) and payload["status"] == "ok", do: throw({:ws, "arkab_refused"})

      form = %{
        "type" => "form",
        "event" => "join",
        "value" => "link=" <> URI.encode(link, &URI.char_unreserved?/1),
        "meta" => %{}
      }

      ws_send(s, 1, Json.encode(["1", "2", topic, "event", form]))
      loop(s, buf, topic, link, deadline, true)
    else
      loop(s, buf, topic, link, deadline, false)
    end
  end

  defp handle(s, buf, topic, link, deadline, true, _ref, event, payload) do
    if event in ["diff", "phx_reply"] do
      case result_reason(Json.encode(payload)) do
        nil -> loop(s, buf, topic, link, deadline, true)
        reason -> {reason == "joined", reason}
      end
    else
      loop(s, buf, topic, link, deadline, true)
    end
  end

  # ------------------------------------------------------------- the websocket ---
  defp send!(s, data) do
    case :gen_tcp.send(s, data) do
      :ok -> :ok
      {:error, _} -> throw({:ws, "no_answer"})
    end
  end

  # A client frame: FIN set, masked, 7/16/64-bit length.
  defp ws_send(s, opcode, data) do
    n = byte_size(data)

    len =
      cond do
        n < 126 -> <<0x80 ||| n>>
        n < 65_536 -> <<0x80 ||| 126, n::16>>
        true -> <<0x80 ||| 127, n::64>>
      end

    key = :crypto.strong_rand_bytes(4)
    send!(s, [<<0x80 ||| opcode>>, len, key, mask(data, key)])
  end

  defp mask(data, <<k0, k1, k2, k3>>) do
    keys = {k0, k1, k2, k3}
    for {b, i} <- Enum.with_index(:binary.bin_to_list(data)), into: <<>>, do: <<bxor(b, elem(keys, rem(i, 4)))>>
  end

  # The next text message (fragments joined); answers pings; {:closed, buf} when the server closes.
  defp ws_recv(s, buf, timeout, msg \\ <<>>) do
    {<<b1, b2>>, buf} = need(s, buf, 2, timeout)
    op = b1 &&& 0x0F
    n = b2 &&& 0x7F
    {n, buf} = ext_len(s, buf, n, timeout)
    {mask, buf} = if (b2 &&& 0x80) != 0, do: need(s, buf, 4, timeout), else: {nil, buf}
    {data, buf} = need(s, buf, n, timeout)
    data = if mask, do: mask(data, mask), else: data

    cond do
      op == 8 ->
        {:closed, buf}

      op == 9 ->
        ws_send(s, 10, data)
        ws_recv(s, buf, timeout, msg)

      op in [0, 1, 2] ->
        msg = msg <> data
        if (b1 &&& 0x80) != 0, do: {:ok, String.replace_invalid(msg), buf}, else: ws_recv(s, buf, timeout, msg)

      true ->
        ws_recv(s, buf, timeout, msg)
    end
  end

  defp ext_len(s, buf, 126, t), do: with({<<n::16>>, buf} <- need(s, buf, 2, t), do: {n, buf})
  defp ext_len(s, buf, 127, t), do: with({<<n::64>>, buf} <- need(s, buf, 8, t), do: {n, buf})
  defp ext_len(_s, buf, n, _t), do: {n, buf}

  # exactly n bytes, from the buffer first; a closed or silent socket ends the conversation
  defp need(_s, buf, n, _t) when byte_size(buf) >= n do
    {binary_part(buf, 0, n), binary_part(buf, n, byte_size(buf) - n)}
  end

  defp need(s, buf, n, t) do
    case :gen_tcp.recv(s, 0, t) do
      {:ok, d} -> need(s, buf <> d, n, t)
      {:error, _} -> throw({:ws, "no_answer"})
    end
  end
end
