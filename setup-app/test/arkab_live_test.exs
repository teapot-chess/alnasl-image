defmodule AlnaslSetup.ArkabLiveTest do
  # valid_link/1 (what a phone may send), the result mapping, and the whole websocket conversation
  # against a fake Arkab (a Phoenix LiveView page and websocket on a test port).
  use ExUnit.Case, async: false
  alias AlnaslSetup.ArkabLive

  describe "valid_link/1" do
    test "accepts a server's join link" do
      for good <- ["https://arkab.example.org/join/AbC_12-x", "http://10.0.0.5:4006/join/k3y"] do
        assert ArkabLive.valid_link(good) == good
      end
    end

    test "a pasted link loses the whitespace around it" do
      assert ArkabLive.valid_link(" https://x.org/join/abc\n") == "https://x.org/join/abc"
    end

    test "refuses everything else" do
      for bad <- [
            "javascript:alert(1)",
            "https://x.org/join/abc?x=1",
            "https://x.org/join/a\nbc",
            "ftp://x.org/join/abc",
            "https://x.org/other/abc",
            "https://user@x.org/join/abc",
            "https://x.org/join/" <> String.duplicate("a", 65),
            "https://x.org:0/join/abc",
            "https://x.org:70000/join/abc",
            "",
            nil
          ] do
        refute ArkabLive.valid_link(bad), "should be refused: #{inspect(bad)}"
      end
    end
  end

  describe "result_reason/1 (Arkab's English words for each result)" do
    test "maps each phrase" do
      for {text, reason} <- [
            {"Joined.", "joined"},
            {"That is not a join link", "not_a_link"},
            {"the link is used up or expired", "used_or_expired"},
            {"this server does not answer from here", "unreachable"},
            {"this is another version of the link", "version"},
            {"it belongs to another hall", "elsewhere"},
            {"this does not look not like a server", "not_a_server"}
          ] do
        assert ArkabLive.result_reason(text) == reason
      end
    end

    test "no phrase, no result" do
      assert ArkabLive.result_reason("{\"rendered\": \"nothing yet\"}") == nil
    end
  end

  describe "join/2" do
    test "a bad link never touches the network" do
      assert ArkabLive.join("nonsense") == {false, "not_a_link"}
      assert ArkabLive.join(nil) == {false, "not_a_link"}
    end

    test "nothing listening: arkab_down" do
      {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(l)
      :gen_tcp.close(l)
      Application.put_env(:alnasl_setup, :arkab_port, port)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :arkab_port) end)
      assert ArkabLive.join("https://x.org/join/abc") == {false, "arkab_down"}
    end

    test "joined: the page, the websocket, the join form, the answer" do
      port = fake_arkab(answer: "<p>Joined.</p>")
      Application.put_env(:alnasl_setup, :arkab_port, port)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :arkab_port) end)

      assert ArkabLive.join("https://x.org/join/abc") == {true, "joined"}
      assert_receive {:fake_arkab, :page, page_req}
      assert page_req =~ "Accept-Language: en"
      assert page_req =~ "Host: 127.0.0.1:#{port}"
      assert_receive {:fake_arkab, :upgrade, up}
      assert up =~ "Origin: http://127.0.0.1:#{port}"
      assert up =~ "Cookie: _arkab_key=abc; other=1"
      assert up =~ "_csrf_token=tok%2Fen%3D"
      assert up =~ "Accept-Language: en"
      assert_receive {:fake_arkab, :frame, join_msg}
      assert [_, _, "lv:phx-Fabc", "phx_join", payload] = jd(join_msg)
      assert payload["session"] == "SESSION" and payload["static"] == "STATIC"
      assert payload["params"]["_csrf_token"] == "tok/en="
      assert_receive {:fake_arkab, :frame, form_msg}
      assert [_, _, "lv:phx-Fabc", "event", ev] = jd(form_msg)

      assert ev == %{
               "type" => "form",
               "event" => "join",
               "value" => "link=https%3A%2F%2Fx.org%2Fjoin%2Fabc",
               "meta" => %{}
             }
    end

    test "Arkab's refusals come back as our reason words" do
      port = fake_arkab(answer: "this link is used up or expired")
      Application.put_env(:alnasl_setup, :arkab_port, port)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :arkab_port) end)
      assert ArkabLive.join("https://x.org/join/abc") == {false, "used_or_expired"}
    end

    test "a page without the LiveView markup is arkab_refused" do
      port = fake_arkab(page: "<html>nothing here</html>")
      Application.put_env(:alnasl_setup, :arkab_port, port)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :arkab_port) end)
      assert ArkabLive.join("https://x.org/join/abc") == {false, "arkab_refused"}
    end

    test "no answer inside the time: no_answer" do
      port = fake_arkab(answer: nil)
      Application.put_env(:alnasl_setup, :arkab_port, port)
      on_exit(fn -> Application.delete_env(:alnasl_setup, :arkab_port) end)
      assert ArkabLive.join("https://x.org/join/abc", 1) == {false, "no_answer"}
    end
  end

  # ------------------------------------------------------------ a fake Arkab ---
  # Serves "/" (a LiveView page with a csrf token and the main div) and answers the websocket upgrade;
  # it sends what it receives to the test process.
  defp fake_arkab(opts) do
    test = self()

    page =
      Keyword.get(opts, :page, """
      <html><head><meta name="csrf-token" content="tok/en="></head><body>
      <div id="phx-Fabc" data-phx-main data-phx-session="SESSION" data-phx-static="STATIC"></div>
      </body></html>
      """)

    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)

    spawn_link(fn ->
      # connection 1: the page
      {:ok, s} = :gen_tcp.accept(l)
      req = read_head(s, "")
      send(test, {:fake_arkab, :page, req})

      :gen_tcp.send(
        s,
        "HTTP/1.1 200 OK\r\nset-cookie: _arkab_key=abc; path=/; HttpOnly\r\nSet-Cookie: other=1; Secure\r\n" <>
          "content-type: text/html\r\nconnection: close\r\ncontent-length: #{byte_size(page)}\r\n\r\n" <> page
      )

      :gen_tcp.close(s)

      # connection 2: the websocket
      with {:ok, s2} <- :gen_tcp.accept(l, 3000) do
        up = read_head(s2, "")
        send(test, {:fake_arkab, :upgrade, up})
        [_, key] = Regex.run(~r/Sec-WebSocket-Key: (\S+)/i, up)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :gen_tcp.send(
          s2,
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
        )

        ws_loop(s2, test, Keyword.get(opts, :answer, "<p>Joined.</p>"), "")
      end
    end)

    port
  end

  defp jd(text), do: elem(AlnaslSetup.Json.decode(text), 1)

  defp read_head(s, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, d} = :gen_tcp.recv(s, 0, 3000)
      read_head(s, acc <> d)
    end
  end

  defp ws_loop(s, test, answer, buf) do
    case read_frame(s, buf) do
      {:ok, text, buf} ->
        send(test, {:fake_arkab, :frame, text})
        [_, ref, topic, event, _] = jd(text)

        cond do
          event == "phx_join" ->
            push(s, ["1", ref, topic, "phx_reply", %{"status" => "ok", "response" => %{}}])

          event == "event" and answer != nil ->
            push(s, [nil, nil, topic, "diff", %{"e" => [answer]}])

          true ->
            :ok
        end

        ws_loop(s, test, answer, buf)

      :closed ->
        :ok
    end
  end

  defp push(s, msg) do
    data = AlnaslSetup.Json.encode(msg)
    n = byte_size(data)
    head = if n < 126, do: <<0x81, n>>, else: <<0x81, 126, n::16>>
    :gen_tcp.send(s, head <> data)
  end

  defp read_frame(s, buf) do
    case buf do
      <<_::1, _::3, 1::4, 1::1, len::7, mask::binary-size(4), payload::binary-size(len), rest::binary>>
      when len < 126 ->
        {:ok, unmask(payload, mask), rest}

      <<_::1, _::3, 1::4, 1::1, 126::7, len::16, mask::binary-size(4), payload::binary-size(len), rest::binary>> ->
        {:ok, unmask(payload, mask), rest}

      _ ->
        case :gen_tcp.recv(s, 0, 5000) do
          {:ok, d} -> read_frame(s, buf <> d)
          _ -> :closed
        end
    end
  end

  defp unmask(payload, <<a, b, c, d>>) do
    key = {a, b, c, d}

    for {byte, i} <- Enum.with_index(:binary.bin_to_list(payload)),
        into: <<>>,
        do: <<Bitwise.bxor(byte, elem(key, rem(i, 4)))>>
  end
end
