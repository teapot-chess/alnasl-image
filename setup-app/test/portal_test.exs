defmodule AlnaslSetup.PortalTest do
  # The captive portal: the route table (port of scripts/test-hotspot.py's portal section) and the
  # HTTP behaviour against a fake setup server on test ports.
  use ExUnit.Case, async: false
  alias AlnaslSetup.{Http, Portal}
  alias AlnaslSetup.Test.Box

  @portal "http://10.42.0.1/"

  describe "route/3" do
    test "every OS probe and every other site gets the redirect to the page (never a 204, never 'Success')" do
      probes = [
        {"captive.apple.com", "/hotspot-detect.html"},
        {"www.apple.com", "/library/test/success.html"},
        {"connectivitycheck.gstatic.com", "/generate_204"},
        {"clients3.google.com", "/generate_204"},
        {"connectivitycheck.android.com", "/generate_204"},
        {"www.google.com", "/gen_204"},
        {"www.msftconnecttest.com", "/connecttest.txt"},
        {"www.msftncsi.com", "/ncsi.txt"},
        {"www.msftconnecttest.com", "/redirect"},
        {"detectportal.firefox.com", "/canonical.html"},
        {"detectportal.firefox.com", "/success.txt"},
        {"nmcheck.gnome.org", "/check_network_status.txt"},
        {"example.com", "/"},
        {"10.42.0.2", "/"},
        {"", "/"},
        {nil, "/"}
      ]

      for {host, path} <- probes do
        assert Portal.route("GET", host, path) == {:redirect, @portal}, "probe #{host}#{path}"
      end
    end

    test "a POST to another host is not passed on" do
      assert {:redirect, _} = Portal.route("POST", "captive.apple.com", "/api/portal/join")
    end

    test "the page itself" do
      assert {:static, "portal.html", "text/html; charset=utf-8"} = Portal.route("GET", "10.42.0.1", "/")
      assert {:static, "portal.html", _} = Portal.route("GET", "10.42.0.1:80", "/")
      assert {:static, "portal.html", _} = Portal.route("GET", "10.42.0.1", "/index.html")
      assert {:static, "portal.js", "text/javascript; charset=utf-8"} = Portal.route("GET", "10.42.0.1", "/portal.js")
      assert {:static, "app.css", "text/css; charset=utf-8"} = Portal.route("GET", "10.42.0.1", "/app.css")
    end

    test "the host is compared in lower case" do
      assert {:static, _, _} = Portal.route("GET", "10.42.0.1:80", "/")
    end

    test "RFC 8908 API, and the calls passed on" do
      assert Portal.route("GET", "10.42.0.1", "/api/captive") == {:captive}
      assert Portal.route("GET", "10.42.0.1", "/api/portal") == {:pass, "/api/portal"}
      assert Portal.route("GET", "10.42.0.1", "/api/portal/scan") == {:pass, "/api/portal/scan"}
      assert Portal.route("POST", "10.42.0.1", "/api/portal/join") == {:pass, "/api/portal/join"}
      assert Portal.route("POST", "10.42.0.1", "/api/portal/arkab-pin") == {:pass, "/api/portal/arkab-pin"}
      assert Portal.route("POST", "10.42.0.1", "/api/portal/arkab-join") == {:pass, "/api/portal/arkab-join"}
    end

    test "anything else on the hotspot is forbidden" do
      for {m, p} <- [
            {"GET", "/api/diag"},
            {"GET", "/api/hotspot"},
            {"GET", "/api/mode"},
            {"POST", "/api/mode"},
            {"POST", "/api/factory-reset"},
            {"POST", "/api/power"},
            {"POST", "/api/system"},
            {"POST", "/api/wifi/connect"},
            {"POST", "/api/wifi/forget"},
            {"GET", "/api/portal/../diag"},
            {"POST", "/"},
            {"PUT", "/api/portal/join"},
            {"GET", "/api/portal/join"}
          ] do
        assert Portal.route(m, "10.42.0.1", p) == {:forbidden}, "#{m} #{p}"
      end
    end

    test "a GET of an unknown non-API path redirects to the page" do
      assert Portal.route("GET", "10.42.0.1", "/whatever") == {:redirect, @portal}
    end

    test "everything passed on is /api/portal*, nothing destructive, not /api/hotspot (it shows the password)" do
      allowed = Portal.pass_get() ++ Portal.pass_post()
      assert Enum.all?(allowed, &String.starts_with?(&1, "/api/portal"))

      refute Enum.any?(allowed, fn p ->
               Enum.any?(~w(reset power mode system update diag hotspot forget), &String.contains?(p, &1))
             end)
    end

    test "it listens on 10.42.0.1 and talks to 127.0.0.1:4041 by default" do
      assert Portal.addr() == "10.42.0.1"
      assert Portal.setup_target() == {"127.0.0.1", 4041}
    end

    test "captive_json is RFC 8908's" do
      assert Portal.captive_json() == %{"captive" => true, "user-portal-url" => @portal}
    end
  end

  describe "over HTTP" do
    setup do
      Box.root!()
      Box.put("/www/portal.html", "<html>the page</html>")
      Box.put("/www/portal.js", "console.log(1)")
      Box.put("/www/app.css", "body{}")
      test = self()

      # the fake setup server (the real one is 127.0.0.1:4041)
      {:ok, _} =
        Http.start_link(
          id: :fake_setup,
          ip: {127, 0, 0, 1},
          port: 0,
          handler: fn req ->
            send(test, {:setup_got, req})

            case req.path do
              "/api/portal" -> {200, [], {:json, %{"ok" => true}}}
              "/api/portal/join" -> {200, [], ~s({"joined": "yes"})}
              "/api/portal/arkab-pin" -> {409, [], {:json, %{"error" => "nope"}}}
              _ -> {404, [], {:json, %{"error" => "unknown"}}}
            end
          end
        )

      setup_port = Http.port(:fake_setup)

      {:ok, _} =
        Portal.start_link(
          id: :portal_test,
          ip: {127, 0, 0, 1},
          port: 0,
          setup: {"127.0.0.1", setup_port},
          www: "/www",
          log_fun: &send(test, {:portal_log, &1})
        )

      %{port: Http.port(:portal_test), setup_port: setup_port}
    end

    defp request(port, raw) do
      {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(s, raw)
      resp = recv_all(s, "")
      :gen_tcp.close(s)
      [head, body] = String.split(resp, "\r\n\r\n", parts: 2)
      [status_line | headers] = String.split(head, "\r\n")
      [_, code | _] = String.split(status_line, " ")

      headers =
        Map.new(headers, fn h ->
          [k, v] = String.split(h, ": ", parts: 2)
          {String.downcase(k), v}
        end)

      {String.to_integer(code), headers, body}
    end

    defp recv_all(s, acc) do
      case :gen_tcp.recv(s, 0, 2000) do
        {:ok, d} -> recv_all(s, acc <> d)
        {:error, _} -> acc
      end
    end

    defp get(port, host, path, extra \\ "") do
      request(port, "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n#{extra}\r\n")
    end

    defp post(port, path, body, extra) do
      request(
        port,
        "POST #{path} HTTP/1.1\r\nHost: 10.42.0.1\r\nConnection: close\r\nContent-Length: #{byte_size(body)}\r\n#{extra}\r\n#{body}"
      )
    end

    test "a probe gets a 302 to the page, with the portal's own headers", %{port: port} do
      {302, h, body} = get(port, "captive.apple.com", "/hotspot-detect.html")
      assert h["location"] == @portal
      assert h["content-type"] == "text/html; charset=utf-8"
      assert h["x-frame-options"] == "DENY"
      assert h["cache-control"] == "no-store"
      assert h["server"] == "alnasl-portal"
      assert body =~ ~s(<a href="http://10.42.0.1/">Alnasl setup</a>)
    end

    test "the page is served from the www directory", %{port: port} do
      {200, h, body} = get(port, "10.42.0.1", "/")
      assert body == "<html>the page</html>"
      assert h["content-type"] == "text/html; charset=utf-8"
      assert h["x-frame-options"] == "DENY"
      {200, h, "console.log(1)"} = get(port, "10.42.0.1:80", "/portal.js")
      assert h["content-type"] == "text/javascript; charset=utf-8"
    end

    test "a missing file is the box being busy, not a crash", %{port: port} do
      File.rm!(sys_path("/www/portal.js"))
      assert {502, _, ~s({"error": "box_busy"})} = get(port, "10.42.0.1", "/portal.js")
    end

    test "HEAD has the headers and no body", %{port: port} do
      {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :gen_tcp.send(s, "HEAD / HTTP/1.1\r\nHost: 10.42.0.1\r\nConnection: close\r\n\r\n")
      resp = recv_all(s, "")
      assert resp =~ "200 OK"
      assert resp =~ "Content-Length: 21"
      assert [_, ""] = String.split(resp, "\r\n\r\n", parts: 2)
    end

    test "/api/captive answers application/captive+json", %{port: port} do
      {200, h, body} = get(port, "10.42.0.1", "/api/captive")
      assert h["content-type"] == "application/captive+json"
      assert body == ~s({"captive": true, "user-portal-url": "http://10.42.0.1/"})
    end

    test "a GET is passed on with Host 127.0.0.1:<setup port>, status and body as they are", %{port: port, setup_port: sp} do
      {200, h, body} = get(port, "10.42.0.1", "/api/portal?x=1")
      assert body == ~s({"ok": true})
      assert h["x-frame-options"] == "DENY"
      assert_receive {:setup_got, req}
      assert req.method == "GET"
      assert req.target == "/api/portal"
      assert req.headers["host"] == "127.0.0.1:#{sp}"
      refute Map.has_key?(req.headers, "x-alnasl-setup")
    end

    test "a POST is passed on with the setup header and the JSON content type", %{port: port, setup_port: sp} do
      {200, _, ~s({"joined": "yes"})} =
        post(port, "/api/portal/join", ~s({"ssid": "Hall"}), "X-Alnasl-Setup: 1\r\nContent-Type: text/plain\r\n")

      assert_receive {:setup_got, req}
      assert req.method == "POST"
      assert req.body == ~s({"ssid": "Hall"})
      assert req.headers["x-alnasl-setup"] == "1"
      assert req.headers["content-type"] == "application/json"
      assert req.headers["host"] == "127.0.0.1:#{sp}"
    end

    test "the setup server's error status is passed back", %{port: port} do
      assert {409, _, ~s({"error": "nope"})} = post(port, "/api/portal/arkab-pin", "{}", "X-Alnasl-Setup: 1\r\n")
    end

    test "a POST without the custom header is forbidden and closes the connection", %{port: port} do
      {403, h, ~s({"error": "forbidden"})} = post(port, "/api/portal/join", "{}", "")
      assert h["connection"] == "close"
      refute_receive {:setup_got, _}, 100
    end

    test "a body over 8192 bytes is refused", %{port: port} do
      {413, h, ~s({"error": "too large"})} =
        post(port, "/api/portal/join", String.duplicate("x", 9000), "X-Alnasl-Setup: 1\r\n")

      assert h["connection"] == "close"
      refute_receive {:setup_got, _}, 100
    end

    test "everything else on the hotspot is forbidden", %{port: port} do
      assert {403, _, ~s({"error": "forbidden"})} = get(port, "10.42.0.1", "/api/diag")
      assert {403, _, _} = post(port, "/api/factory-reset", "{}", "X-Alnasl-Setup: 1\r\n")
      refute_receive {:setup_got, _}, 100
    end

    test "the setup server not answering is 502 box_busy" do
      {:ok, _} =
        Portal.start_link(
          id: :portal_dead,
          ip: {127, 0, 0, 1},
          port: 0,
          setup: {"127.0.0.1", closed_port()},
          www: "/www"
        )

      port = Http.port(:portal_dead)
      assert {502, _, ~s({"error": "box_busy"})} = get(port, "10.42.0.1", "/api/portal/scan")
    end

    test "the log line is method, path (no query) and status", %{port: port} do
      get(port, "10.42.0.1", "/api/portal?secret=1")
      assert_receive {:portal_log, "GET /api/portal 200"}
      refute_received {:portal_log, "GET /api/portal?secret=1 200"}
    end
  end

  defp sys_path(p), do: AlnaslSetup.Sys.path(p)

  defp closed_port do
    {:ok, l} = :gen_tcp.listen(0, [ip: {127, 0, 0, 1}])
    {:ok, p} = :inet.port(l)
    :gen_tcp.close(l)
    p
  end
end
