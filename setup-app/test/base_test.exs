defmodule AlnaslSetup.BaseTest do
  # The shared pieces: Python-compatible JSON, files, commands, the HTTP server.
  use ExUnit.Case, async: false
  alias AlnaslSetup.{Http, Json, Sys}
  alias AlnaslSetup.Test.Box

  describe "Json.encode (as Python's json.dumps)" do
    test "separators, sorted keys, literals" do
      assert Json.encode(%{"b" => 1, "a" => [true, false, nil]}) == ~s({"a": [true, false, null], "b": 1})
      assert Json.encode(%{}) == "{}"
      assert Json.encode([]) == "[]"
    end

    test "floats as Python prints them" do
      assert Json.encode(1.0) == "1.0"
      assert Json.encode(0.5) == "0.5"
      assert Json.encode(1_730_000_000.25) == "1730000000.25"
      assert Json.encode(1.0e16) == "1e+16"
      assert Json.encode(1.5e-7) == "1.5e-07"
    end

    test "ensure_ascii escapes" do
      assert Json.encode("café") == ~s("caf\\u00e9")
      assert Json.encode("a\"b\\c\n\t") == ~s("a\\"b\\\\c\\n\\t")
      assert Json.encode(<<1>>) == ~s("\\u0001")
      assert Json.encode("😀") == ~s("\\ud83d\\ude00")
      assert Json.encode(<<0xFF, ?a>>) == ~s("\\ufffda")
    end

    test "decode round trip" do
      v = %{"x" => [1, 2.5, "é", nil], "y" => %{"z" => true}}
      assert {:ok, ^v} = Json.decode(Json.encode(v))
      assert Json.decode_or_nil("nope") == nil
    end
  end

  describe "Sys" do
    @tag :unix
    test "write_atomic follows a symlink and replaces the target" do
      root = Box.root!()
      Box.put("/data/etc/alnasl/keyboard.conf", "old")
      File.mkdir_p!(Path.join(root, "etc/alnasl"))
      :ok = File.ln_s(Path.join(root, "data/etc/alnasl/keyboard.conf"), Path.join(root, "etc/alnasl/keyboard.conf"))
      Sys.write_atomic("/etc/alnasl/keyboard.conf", "new", 0o600)
      assert File.read!(Path.join(root, "data/etc/alnasl/keyboard.conf")) == "new"
      assert {:ok, %{type: :symlink}} = File.lstat(Path.join(root, "etc/alnasl/keyboard.conf"))
      refute File.exists?(Path.join(root, "data/etc/alnasl/keyboard.conf.new"))
    end

    test "read with a default, path under the fake root" do
      Box.root!()
      assert Sys.read("/nope", "dflt") == "dflt"
      Box.put("/etc/x", "y")
      assert Sys.read("/etc/x") == "y"
    end

    test "the runner seam records commands" do
      Box.runner!(fn
        ["systemctl", "is-active", _] -> {0, "active\n"}
        _ -> nil
      end)

      assert Sys.run(["systemctl", "is-active", "x.service"]) == {0, "active\n"}
      assert Sys.run(["true"]) == {0, ""}
      assert Box.ran() == [["systemctl", "is-active", "x.service"], ["true"]]
    end

    @tag :unix
    test "a missing command" do
      assert {127, "(not installed: no-such-cmd-xyz)\n"} = Sys.runo(["no-such-cmd-xyz"])
      assert {127, _} = Sys.run(["no-such-cmd-xyz"])
    end
  end

  describe "Http" do
    setup do
      handler = fn
        %{path: "/json"} = r -> {200, [], %{"method" => r.method, "q" => r.query}}
        %{path: "/big", body: :too_large} -> {413, [], %{"error" => "too large"}}
        %{path: "/echo", body: b} -> {200, [{"Content-Type", "text/plain"}], b}
        %{path: "/close"} -> {403, [], %{"error" => "forbidden"}, :close}
        _ -> {404, [], %{"error" => "not found"}}
      end

      id = {:test, System.unique_integer()}
      {:ok, pid} = Http.start_link(id: id, ip: {127, 0, 0, 1}, port: 0, handler: handler, max_body: 10)
      on_exit(fn -> Process.exit(pid, :kill) end)
      %{port: Http.port(id)}
    end

    defp raw(port, data) do
      {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      :ok = :gen_tcp.send(s, data)
      out = recv_all(s, "")
      :gen_tcp.close(s)
      out
    end

    defp recv_all(s, acc) do
      case :gen_tcp.recv(s, 0, 500) do
        {:ok, d} -> recv_all(s, acc <> d)
        {:error, _} -> acc
      end
    end

    test "JSON answer, keep-alive serves two requests on one connection", %{port: port} do
      out = raw(port, "GET /json?a=1 HTTP/1.1\r\nHost: x\r\n\r\nGET /json HTTP/1.1\r\nHost: x\r\n\r\n")
      assert [_, _, _] = String.split(out, "HTTP/1.1 200 OK")
      assert out =~ "Content-Type: application/json"
      assert out =~ "Cache-Control: no-store"
      assert out =~ ~s({"method": "GET", "q": "a=1"})
    end

    test "body read by Content-Length; too large is not read and closes", %{port: port} do
      assert raw(port, "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello") =~
               ~r/Content-Length: 5\r\n.*\r\n\r\nhello$/s

      out = raw(port, "POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: 50\r\n\r\n")
      assert out =~ "413" and out =~ "Connection: close"
    end

    test "HEAD has no body; a handler can close", %{port: port} do
      out = raw(port, "HEAD /json HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      assert out =~ "Content-Length: "
      refute out =~ "method"
      assert raw(port, "GET /close HTTP/1.1\r\n\r\n") =~ "Connection: close"
    end

    test "garbage gets a 400", %{port: port} do
      assert raw(port, "\x01\x02 nonsense\r\n\r\n") =~ "400"
    end
  end
end
