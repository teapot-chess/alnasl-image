Code.require_file("server_fakes.exs", __DIR__)

defmodule AlnaslSetup.ServerTest do
  # The setup server over HTTP, as the pages, the kiosk watchdog and the shell scripts see it: the real
  # server on a free port, a fake root (Box.root!) and fake commands (Box.runner!). The HTTP smoke
  # checks in scripts/verify.sh are part of this; so is every JSON shape the pages read.
  use ExUnit.Case, async: false
  alias AlnaslSetup.{Http, Json, Server, Sys, Wifi}
  alias AlnaslSetup.Server.Net
  alias AlnaslSetup.Test.Box

  @www "/usr/local/share/alnasl-setup/www"
  @splash "/usr/share/alnasl/splash"

  @messages %{
    "states" => %{
      "reboot" => %{"title" => "Restarting"},
      "shutdown" => %{"title" => "Off"},
      "reset-1" => %{"title" => "Erasing", "steps" => 3},
      "update-os" => %{"title" => "Updating", "steps" => 4, "bar" => true}
    },
    "mono" => %{"font" => "DejaVu Sans Mono"},
    "logview" => %{"lines" => 12},
    "geometry" => %{"sub_y" => 300},
    "glyphs" => %{"1080" => %{"advance" => %{"a" => 20}, "names" => %{"a" => "a"}, "height" => 40}}
  }

  def default_answer(argv) do
    case argv do
      ["systemctl", "is-enabled", _] -> {1, "disabled\n"}
      ["systemctl", "is-active", _] -> {3, "inactive\n"}
      ["wpa_cli" | _] -> {255, "Failed to connect to non-global ctrl_ifname: wlan0  error: No such file or directory\n"}
      ["ip", "-j" | _] -> {0, "[]\n"}
      ["getent" | _] -> {2, ""}
      ["stat", "-f" | _] -> {0, "4096 1000000 500000\n"}
      _ -> {0, ""}
    end
  end

  # fake commands: `over` answers first (nil = not mine), then the defaults
  defp runner(over \\ fn _ -> nil end) do
    Box.runner!(fn argv -> over.(argv) || default_answer(argv) end)
  end

  setup do
    Box.root!()

    env = [
      later: :inline,
      wait_scale: 0.01,
      net_confirm_seconds: 1,
      res_confirm_seconds: 1,
      modules: %{
        bootlog: AlnaslSetup.Test.FakeBootlog,
        bootlog_follower: AlnaslSetup.Test.FakeFollower,
        hotspot: AlnaslSetup.Test.FakeHotspot,
        arkab_live: AlnaslSetup.Test.FakeArkabLive,
        system_update: AlnaslSetup.Test.FakeSystemUpdate
      }
    ]

    for {k, v} <- env, do: Application.put_env(:alnasl_setup, k, v)

    on_exit(fn ->
      for k <- Keyword.keys(env) ++ [:connect_ports, :help_url, :fake_sysupd],
          do: Application.delete_env(:alnasl_setup, k)
    end)

    runner()
    Box.put(@www <> "/index.html", "<html><script src=\"/app.js\"></script></html>")
    Box.put(@www <> "/app.js", "fetch('/api/resolution')")
    Box.put(@www <> "/app.css", "body{}")
    Box.put(@www <> "/screen.html", "<html>fetch('/api/bootscreen')</html>")
    Box.put(@www <> "/logo.svg", "<svg/>")
    Box.put(@www <> "/data.bin", "xx")
    Box.put(@splash <> "/alnasl-splash.png", "\x89PNG-1")
    Box.put(@splash <> "/screens/nl/reset-2.png", "\x89PNG-2")
    Box.put(@splash <> "/messages.json", Json.encode(@messages))
    Box.put("/etc/shadow.png", "secret")

    start_supervised!({Server, port: 0})
    %{port: Server.port()}
  end

  # ------------------------------------------------------------------------------------- client --

  defp request(method, path, opts \\ []) do
    port = Server.port()
    host = Keyword.get(opts, :host, "127.0.0.1:#{port}")
    body = Keyword.get(opts, :body, "")
    body = if is_binary(body), do: body, else: Json.encode(body)
    xh = if method == "POST", do: [{"X-Alnasl-Setup", "1"}], else: []
    hdrs = Keyword.get(opts, :headers, xh)
    clen = Keyword.get(opts, :content_length, byte_size(body))

    data = [
      "#{method} #{path} HTTP/1.1\r\n",
      if(host, do: "Host: #{host}\r\n", else: ""),
      Enum.map(hdrs, fn {k, v} -> "#{k}: #{v}\r\n" end),
      if(method == "POST", do: "Content-Type: application/json\r\n", else: ""),
      "Content-Length: #{clen}\r\nConnection: close\r\n\r\n",
      body
    ]

    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(s, data)
    raw = recv_all(s, "")
    :gen_tcp.close(s)
    [head, rbody] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | lines] = String.split(head, "\r\n")
    [_, code | _] = String.split(status_line, " ")

    headers =
      Map.new(lines, fn l ->
        [k, v] = String.split(l, ": ", parts: 2)
        {String.downcase(k), v}
      end)

    %{status: String.to_integer(code), headers: headers, body: rbody, json: Json.decode_or_nil(rbody)}
  end

  defp recv_all(s, acc) do
    case :gen_tcp.recv(s, 0, 60_000) do
      {:ok, d} -> recv_all(s, acc <> d)
      {:error, _} -> acc
    end
  end

  defp get(path, opts \\ []), do: request("GET", path, opts)
  defp post(path, body, opts \\ []), do: request("POST", path, Keyword.put(opts, :body, body))
  defp json(path), do: get(path).json
  defp ok!(%{status: 200, json: j}), do: j

  defp state_json, do: Json.decode_or_nil(Sys.read("/var/lib/alnasl-setup/state.json"))
  defp ran?(argv), do: argv in Box.ran()
  defp mode_of(p), do: Bitwise.band(File.stat!(Sys.path(p)).mode, 0o777)
  defp hostname, do: :inet.gethostname() |> elem(1) |> to_string()

  defp done!, do: Box.put("/var/lib/alnasl-setup/done", "1\n")

  # a listener that answers nothing: "the role's app is up"
  defp listening_port do
    {:ok, ls} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, p} = :inet.port(ls)
    on_exit(fn -> :gen_tcp.close(ls) end)
    p
  end

  # ------------------------------------------------------------------------------------ security --

  describe "the rules every request goes through" do
    test "/healthz answers, first and plainly" do
      r = get("/healthz")
      assert r.status == 200 and r.body == ~s({"ok": true})
      assert r.headers["content-type"] == "application/json"
      assert r.headers["server"] =~ "alnasl-setup"
      assert r.headers["cache-control"] == "no-store"
    end

    test "a foreign Host is refused, on every GET", %{port: port} do
      for p <- ~w(/api/state /api/diag /api/bootlog /healthz /), host <- ["evil.example:4041", "127.0.0.1:1", ""] do
        r = get(p, host: host)
        assert r.status == 403 and r.json == %{"error" => "forbidden"}, "#{p} #{host}"
      end

      assert get("/api/mode", host: nil).status == 403
      assert get("/api/mode", host: "localhost:#{port}").status == 200
    end

    test "a POST without X-Alnasl-Setup: 1 is refused and the connection closes" do
      for h <- [[], [{"X-Alnasl-Setup", "2"}], [{"X-Alnasl-Setup", "true"}]] do
        r = post("/api/lang", %{"lang" => "nl"}, headers: h)
        assert r.status == 403 and r.json == %{"error" => "forbidden"}
        assert r.headers["connection"] == "close"
      end

      r = post("/api/lang", %{"lang" => "nl"}, host: "evil.example:4041")
      assert r.status == 403 and r.headers["connection"] == "close"
      assert state_json() == nil
    end

    test "the refused POSTs change nothing (verify.sh)" do
      assert post("/api/diag/save", %{}, headers: []).status == 403
      assert post("/api/mode", %{"mode" => "slave", "confirm" => "SWITCH"}, headers: []).status == 403
      assert post("/api/reset", %{"confirm" => "RESET"}, headers: []).status == 403
      assert post("/api/resolution", %{}, headers: []).status == 403
      assert Sys.read("/var/lib/alnasl-setup/mode") == ""
      refute Enum.any?(Box.ran(), &match?(["systemctl", "start", "--no-block", "alnasl-reset.service"], &1))
    end

    test "a body over 20000 bytes gets 413" do
      r = post("/api/lang", "", content_length: 20_001)
      assert r.status == 413 and r.json == %{"error" => "too large"}
      assert post("/api/lang", ~s({"lang": "nl", "pad": "#{String.duplicate("x", 19_960)}"})).status == 200
    end

    test "bad JSON is a 400 with an error text" do
      for b <- ["{", "nope", "{\"a\": }", "[1,"] do
        r = post("/api/lang", b)
        assert r.status == 400 and is_binary(r.json["error"]) and r.json["error"] != ""
      end

      assert post("/api/lang", "").json == %{"ok" => true}
    end

    test "a body that is JSON but not an object is an internal error where it is read" do
      assert post("/api/lang", "[1]").status == 500
      assert post("/api/lang", "[1]").json == %{"error" => "internal error"}
      assert post("/api/resolution/confirm", "[1]").status == 200
    end

    test "validation errors are a 400 with the message" do
      r = post("/api/hostname", %{"hostname" => "a b;rm"})
      assert r.status == 400
      assert r.json == %{"error" => "Use letters, digits and hyphens only (1 to 32 characters)."}
    end

    test "unknown paths are 404 not found" do
      for p <- ~w(/api/nope /nope.txt /api/) do
        r = get(p)
        assert r.status == 404 and r.json == %{"error" => "not found"}
      end

      assert post("/api/nope", %{}).json == %{"error" => "not found"}
      assert post("/api/nope", %{}).status == 404
    end

    test "other methods are not served" do
      r = request("PUT", "/api/state")
      assert r.status == 501
    end

    test "favicon is an empty 204" do
      r = get("/favicon.ico")
      assert r.status == 204 and r.body == ""
    end
  end

  # ------------------------------------------------------------------------------- pages / static --

  describe "the start page and the static files" do
    test "/ sends a box that is not set up to the wizard" do
      r = get("/")
      assert r.status == 302 and r.headers["location"] == "/setup"
      assert Sys.exists?("/run/alnasl-kiosk/painted")
    end

    test "/ sends a small screen's kiosk to the compact page, set up or not; /api/compact says what to show" do
      Box.put("/run/alnasl-small-screen/state.json", ~s({"ui": "compact", "status": "ready"}))
      assert get("/").headers["location"] == "/compact"
      done!()
      assert get("/").headers["location"] == "/compact"
      assert get("/compact").status == 200
      r = get("/api/compact")
      assert r.status == 200 and r.body =~ ~s("view") and r.body =~ ~s("qr_left") and r.body =~ ~s("rows")
      # a panel that never came up: the picture is on HDMI, and so are the big pages
      Box.put("/run/alnasl-small-screen/state.json", ~s({"ui": "compact", "status": "no_panel"}))
      assert get("/").headers["location"] == "/menu"
    end

    test "/ sends a set-up box to the menu when its app is not up" do
      done!()
      assert get("/").headers["location"] == "/menu"
    end

    test "/ sends a set-up box to its role's page when that is wanted and up" do
      done!()
      Application.put_env(:alnasl_setup, :connect_ports, %{4050 => listening_port()})
      Box.put("/run/alnasl-mode/role", "arkab\n")

      runner(fn
        ["systemctl", "is-enabled", "arkab.service"] -> {0, "enabled\n"}
        _ -> nil
      end)

      assert get("/").headers["location"] == "http://localhost:4050/"
      assert json("/api/bootscreen")["alnasl_up"] == true
    end

    test "a restarted browser goes back to the menu page it was on (resume), within 180 s" do
      done!()
      assert ok!(get("/api/ping?p=%2Fsettings%2Fnetwork%3Ftab%3Dwifi&first=1")) == %{"ok" => true}
      assert get("/").headers["location"] == "/settings/network?tab=wifi"
      assert Sys.read("/run/alnasl-kiosk/ping") =~ ~r/^\d+\t\/settings\/network\?tab=wifi\n$/
      busy = json("/api/kiosk-busy")
      assert busy["busy"] == true and busy["page"] == "/settings/network?tab=wifi" and busy["age"] in [0, 1]

      # an injected page is not a page
      get("/api/ping?p=%2Fx%0D%0AInjected%3A%201")
      assert Sys.read("/run/alnasl-kiosk/ping") =~ ~r/^\d+\t\n$/

      get("/api/ping?p=")
      assert get("/").headers["location"] == "/menu"
    end

    test "the wizard page is not resumed once setup is done" do
      get("/api/ping?p=/setup")
      assert get("/").headers["location"] == "/setup"
      done!()
      assert get("/").headers["location"] == "/menu"
    end

    test "a ping file from before a restart counts (the watchdog's file)" do
      done!()
      now = trunc(Sys.now()) - 10
      Box.put("/run/alnasl-kiosk/ping", "#{now}\t/diag\n")
      assert get("/").headers["location"] == "/diag"
      busy = json("/api/kiosk-busy")
      assert busy["busy"] == true and busy["age"] in 9..12
      Box.put("/run/alnasl-kiosk/ping", "#{now - 500}\t/diag\n")
      assert get("/").headers["location"] == "/menu"
    end

    test "kiosk-busy with no ping at all" do
      assert json("/api/kiosk-busy") == %{"busy" => false, "page" => "", "age" => nil}
    end

    test "/boot and /screen are the boot screen" do
      for p <- ~w(/boot /screen) do
        r = get(p)
        assert r.status == 200 and r.body =~ "api/bootscreen"
        assert r.headers["content-type"] == "text/html; charset=utf-8"
      end

      assert Sys.exists?("/run/alnasl-kiosk/painted")
    end

    test "splash pictures, never outside the splash directory" do
      r = get("/splash/alnasl-splash.png")
      assert r.status == 200 and r.body == "\x89PNG-1"
      assert r.headers["content-type"] == "image/png" and r.headers["cache-control"] == "max-age=86400"
      assert get("/splash/screens/nl/reset-2.png").status == 200
      assert get("/splash/../../../../etc/shadow.png").status == 404
      assert get("/splash/../../../../etc/shadow.png").json == %{"error" => "not found"}
      assert get("/splash/nope.png").status == 404
      assert get("/splash/messages.json").status == 404
    end

    test "static files with their types; the page paths are the app" do
      r = get("/app.js")
      assert r.status == 200 and r.headers["content-type"] == "text/javascript; charset=utf-8"
      assert get("/app.css").headers["content-type"] == "text/css; charset=utf-8"
      assert get("/logo.svg").headers["content-type"] == "image/svg+xml"
      assert get("/data.bin").headers["content-type"] == "application/octet-stream"
      assert get("/index.html").headers["content-type"] == "text/html; charset=utf-8"

      for p <- ~w(/setup /menu /settings /info /diag /help /settings/network /settings/x/y) do
        r = get(p)
        assert r.status == 200 and r.body =~ "app.js", p
      end

      assert get("/../../../../etc/shadow.png").status == 404
      assert get("/settingsx").status == 404
      assert get("/app.js?v=1").status == 200
    end
  end

  # -------------------------------------------------------------------------------- state / lang --

  describe "state, language, keyboard" do
    test "/api/state has everything the wizard needs" do
      s = json("/api/state")
      # v7.3: no small screen has run
      assert s["touch"] == "off"
      assert s["done"] == false and s["lang"] == "en"
      assert length(s["layouts"]) == 10
      assert hd(s["layouts"]) == %{"id" => "be", "label" => "Belgian (AZERTY)"}
      assert s["keyboard"] == %{}

      assert s["services"] == %{
               "alnasl" => %{"enabled" => false, "active" => false},
               "kiosk" => %{"enabled" => false, "active" => false}
             }

      assert s["scale"] == "100" and s["alnasl_up"] == false and s["role_up"] == false and s["role_port"] == 4040

      assert s["mode"] == %{
               "mode" => "master",
               "role" => "alnasl",
               "roles" => ["alnasl", "arkab", "polis", "nunki"],
               "set" => false,
               "running" => "master",
               "running_role" => "alnasl"
             }
    end

    test "v7.3 Settings > Touch screen: the state of the boot, a calibration refused while the stylus is off" do
      t = json("/api/touch")
      assert t["touch"] == "off" and t["status"] == "not_started" and t["screen"] == "hdmi" and t["stored"] == false

      Box.put(
        "/run/alnasl-small-screen/state.json",
        ~s({"screen": "waveshare35a", "preset": "waveshare35a", "touch": "xpt2046", "status": "ready", "rotate": 0, "card": "card1", "size": "480x320", "source": "default", "device": "/dev/input/event0"})
      )

      t = json("/api/touch")
      assert t["touch"] == "xpt2046" and t["status"] == "ready" and t["mode"] == "480x320" and t["device"] == true
      assert json("/api/state")["touch"] == "xpt2046"
      assert json("/api/resolution")["forced"] == true
      r = post("/api/resolution", %{"mode" => "auto"})
      assert r.status == 400 and r.json["error"] =~ "alnasl-screen.txt"

      Box.put("/run/alnasl-small-screen/state.json", ~s({"screen": "hdmi", "touch": "off", "status": "off"}))

      r =
        post("/api/touch/calibrate", %{
          "samples" => [
            [0.15, 0.15, 0.15, 0.15],
            [0.85, 0.15, 0.85, 0.15],
            [0.85, 0.85, 0.85, 0.85],
            [0.15, 0.85, 0.15, 0.85]
          ]
        })

      assert r.status == 400 and r.json["error"] =~ "touch screen is off"
      assert ok!(post("/api/touch/reset", %{})) == %{"ok" => true}
    end

    test "POST /api/lang" do
      assert ok!(post("/api/lang", %{"lang" => "nl"})) == %{"ok" => true}
      assert json("/api/state")["lang"] == "nl"
      assert Sys.read("/var/lib/alnasl-setup/state.json") == ~s({"lang": "nl"})
      post("/api/lang", %{"lang" => "fr"})
      assert json("/api/state")["lang"] == "nl"
    end

    test "set_state keeps what was there" do
      Box.put("/var/lib/alnasl-setup/state.json", ~s({"support_url": "https://x.example/u", "n": 1}))
      post("/api/lang", %{"lang" => "nl"})
      assert state_json() == %{"support_url" => "https://x.example/u", "n" => 1, "lang" => "nl"}
    end

    test "keyboard: the first console keymap that exists" do
      runner(fn
        ["find", "/usr/share/keymaps" | rest] ->
          if "fr-latin1.map*" in rest, do: {0, "/usr/share/keymaps/i386/azerty/fr-latin1.map.gz\n"}, else: {1, ""}

        _ ->
          nil
      end)

      assert ok!(post("/api/keyboard", %{"layout" => "fr"})) == %{"console_keymap" => "fr-latin1"}

      assert Sys.read("/etc/alnasl/keyboard.conf") ==
               ~s(KBD_ID="fr"\nKBD_LAYOUT="fr"\nKBD_VARIANT=""\nKBD_CONSOLE="fr-latin1"\n)

      assert Sys.read("/etc/vconsole.conf") == "KEYMAP=fr-latin1\n"
      assert ran?(["loadkeys", "fr-latin1"])

      assert json("/api/state")["keyboard"] == %{
               "KBD_ID" => "fr",
               "KBD_LAYOUT" => "fr",
               "KBD_VARIANT" => "",
               "KBD_CONSOLE" => "fr-latin1"
             }
    end

    test "keyboard: no console keymap, and an unknown layout" do
      assert ok!(post("/api/keyboard", %{"layout" => "us-intl", "restart_kiosk" => true})) == %{"console_keymap" => ""}
      assert Sys.read("/etc/alnasl/keyboard.conf") =~ ~s(KBD_LAYOUT="us"\nKBD_VARIANT="intl")
      refute Sys.exists?("/etc/vconsole.conf")
      r = post("/api/keyboard", %{"layout" => "klingon"})
      assert r.status == 400 and r.json == %{"error" => "unknown keyboard layout"}
    end

    test "scale" do
      assert ok!(post("/api/scale", %{"scale" => "125"})) == %{"ok" => true}
      assert Sys.read("/etc/alnasl/kiosk.conf") == ~s(KIOSK_RES="auto"\nKIOSK_SCALE="125"\n)
      assert json("/api/state")["scale"] == "125"
      assert post("/api/scale", %{"scale" => 90}).json == %{"error" => "Unsupported scale."}

      assert post("/api/scale", %{"scale" => "abc"}).json == %{
               "error" => "invalid literal for int() with base 10: 'abc'"
             }

      assert post("/api/scale", %{"scale" => nil}).status == 500
      assert ok!(post("/api/scale", %{"scale" => 150.0})) == %{"ok" => true}
    end
  end

  # ---------------------------------------------------------------------------------------- wifi --

  @ieee_psk "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"

  describe "the wpa_supplicant configuration" do
    test "parse: hex and quoted SSIDs, a clear passphrase becomes the PSK (802.11i test vector)" do
      Box.put(
        Wifi.wpa_conf(),
        "country=NL\nnetwork={\n\tssid=\"IEEE\"\n\tpsk=\"password\"\n\tpriority=3\n}\n" <>
          "network={\n\tssid=486F6D65\n\tpsk=#{@ieee_psk}\n\tscan_ssid=1\n}\nnetwork={\n\tssid=\"Open\"\n\tkey_mgmt=NONE\n\tpriority=\n}\n" <>
          "network={\n\tkey_mgmt=NONE\n}\n"
      )

      assert Wifi.parse_wpa() ==
               {"NL",
                [
                  %{"ssid" => "49454545", "psk" => @ieee_psk, "hidden" => false, "prio" => 3},
                  %{"ssid" => "486f6d65", "psk" => @ieee_psk, "hidden" => true, "prio" => 0},
                  %{"ssid" => "4f70656e", "psk" => nil, "hidden" => false, "prio" => 0}
                ]}
    end

    test "no file: Belgium, no networks" do
      assert Wifi.parse_wpa() == {"BE", []}
    end

    test "write then parse is the same, the file is the exact text" do
      nets = [
        %{"ssid" => "486f6d654e6574", "psk" => @ieee_psk, "hidden" => false, "prio" => 1},
        %{"ssid" => "4f70656e4e6574", "psk" => nil, "hidden" => true, "prio" => 0}
      ]

      Wifi.write_wpa("BE", nets)
      assert Wifi.parse_wpa() == {"BE", nets}

      assert Sys.read(Wifi.wpa_conf()) ==
               "ctrl_interface=/run/wpa_supplicant\nctrl_interface_group=0\nupdate_config=0\ncountry=BE\n" <>
                 "network={\n\tssid=486f6d654e6574\n\tpsk=#{@ieee_psk}\n\tpriority=1\n}\n" <>
                 "network={\n\tssid=4f70656e4e6574\n\tkey_mgmt=NONE\n\tscan_ssid=1\n\tpriority=0\n}\n"
    end

    @tag :unix
    test "the configuration file is 0600" do
      Wifi.write_wpa("BE", [])
      assert mode_of(Wifi.wpa_conf()) == 0o600
    end

    test "saved networks, and forgetting one, and the country" do
      Wifi.write_wpa("BE", [
        %{"ssid" => Wifi.hexify("Café"), "psk" => @ieee_psk, "hidden" => true, "prio" => 1},
        %{"ssid" => Wifi.hexify("Open"), "psk" => nil, "hidden" => false, "prio" => 2}
      ])

      assert json("/api/wifi/saved") == %{
               "country" => "BE",
               "saved" => [
                 %{"ssid" => "Café", "secured" => true, "hidden" => true},
                 %{"ssid" => "Open", "secured" => false, "hidden" => false}
               ]
             }

      assert ok!(post("/api/wifi/forget", %{"ssid" => "Café"})) == %{"ok" => true}
      assert ran?(["wpa_cli", "-p", "/run/wpa_supplicant", "-i", "wlan0", "reconfigure"])
      assert [%{"ssid" => "Open"}] = json("/api/wifi/saved")["saved"]
      assert ok!(post("/api/wifi/country", %{"country" => "nl"})) == %{"ok" => true}
      assert elem(Wifi.parse_wpa(), 0) == "NL"
      assert post("/api/wifi/country", %{"country" => "NLD"}).json == %{"error" => "The country must be two letters."}
    end

    test "wpa_unescape" do
      assert Wifi.wpa_unescape("Caf\\xc3\\xa9") == "Café"
      assert Wifi.wpa_unescape("plain") == "plain"
    end
  end

  describe "Wi-Fi connect" do
    test "validation" do
      assert_raise ArgumentError, "The network name must be 1 to 32 bytes.", fn -> Wifi.connect("", "", false, "BE") end

      assert_raise ArgumentError, "The network name must be 1 to 32 bytes.", fn ->
        Wifi.connect(String.duplicate("é", 17), "", false, "BE")
      end

      assert_raise ArgumentError, "The passphrase must be 8 to 63 characters.", fn ->
        Wifi.connect("x", "short", false, "BE")
      end

      assert_raise ArgumentError, "The country must be two letters.", fn -> Wifi.connect("x", "", false, "B1") end
      r = post("/api/wifi/connect", %{"ssid" => "x", "passphrase" => "1234567"})
      assert r.status == 400 and r.json == %{"error" => "The passphrase must be 8 to 63 characters."}
    end

    test "while the hotspot has the radio: handed to the hotspot daemon, 0600, never logged" do
      Box.put("/run/alnasl-hotspot/active", "")

      r =
        ok!(
          post("/api/wifi/connect", %{"ssid" => "Hall", "passphrase" => "hallpass1", "hidden" => 1, "country" => "nl"})
        )

      assert r == %{"ok" => false, "reason" => "hotspot_handover", "pending" => true}

      assert Json.decode_or_nil(Sys.read("/run/alnasl-hotspot/join.json")) ==
               %{"ssid" => "Hall", "passphrase" => "hallpass1", "hidden" => true, "country" => "NL"}

      refute Sys.exists?("/run/alnasl-hotspot/join.json.new")
    end

    @tag :unix
    test "the hand-over file is 0600 in a 0700 directory" do
      Box.put("/run/alnasl-hotspot/active", "")
      File.chmod!(Sys.path("/run/alnasl-hotspot"), 0o700)
      Wifi.connect("Hall", "hallpass1", false, "BE")
      assert mode_of("/run/alnasl-hotspot/join.json") == 0o600
    end

    @tag :unix
    test "a symlink planted at the temporary name is not followed" do
      Box.put("/run/alnasl-hotspot/active", "")
      victim = Box.put("/etc/victim", "keep")
      File.ln_s!(victim, Sys.path("/run/alnasl-hotspot/join.json.new"))
      Wifi.connect("Hall", "hallpass1", false, "BE")
      assert File.read!(victim) == "keep"
      assert Sys.read("/run/alnasl-hotspot/join.json") =~ "hallpass1"
    end

    defp wifi_box(status) do
      Box.put("/sys/class/net/wlan0/operstate", "up\n")

      runner(fn
        ["wpa_cli", _, _, _, _, "ping"] ->
          {0, "PONG\n"}

        ["wpa_cli", _, _, _, _, "status"] ->
          {0, status}

        ["wpa_cli" | _] ->
          {0, "OK\n"}

        ["ip", "-j", "-4", "addr", "show", "wlan0"] ->
          {0, ~s([{"addr_info": [{"local": "192.168.1.77", "prefixlen": 24}]}])}

        _ ->
          nil
      end)
    end

    test "connected: the network is saved with the next priority" do
      Wifi.write_wpa("BE", [%{"ssid" => Wifi.hexify("Old"), "psk" => nil, "hidden" => false, "prio" => 4}])
      wifi_box("wpa_state=COMPLETED\nssid=Hall\\x20A\n")

      assert ok!(post("/api/wifi/connect", %{"ssid" => "Hall A", "passphrase" => "password", "country" => "BE"})) ==
               %{"ok" => true, "ip" => "192.168.1.77"}

      {"BE", [_old, new]} = Wifi.parse_wpa()
      assert new["ssid"] == Wifi.hexify("Hall A") and new["prio"] == 5 and new["hidden"] == false
      assert new["psk"] == Base.encode16(:crypto.pbkdf2_hmac(:sha, "password", "Hall A", 4096, 32), case: :lower)
      assert ran?(["iw", "reg", "set", "BE"])
    end

    test "a wrong passphrase: the old configuration comes back" do
      old = "country=BE\nnetwork={\n\tssid=4f6c64\n\tkey_mgmt=NONE\n\tpriority=1\n}\n"
      Box.put(Wifi.wpa_conf(), old)
      wifi_box("wpa_state=4WAY_HANDSHAKE\n")

      assert ok!(post("/api/wifi/connect", %{"ssid" => "Hall", "passphrase" => "password1"})) ==
               %{"ok" => false, "reason" => "wrong_passphrase"}

      assert Sys.read(Wifi.wpa_conf()) == old
    end

    test "never seen: not_found; associating only: rejected" do
      wifi_box("wpa_state=SCANNING\n")
      assert Wifi.connect("Hall", "", nil, "BE") == %{"ok" => false, "reason" => "not_found"}
      wifi_box("wpa_state=ASSOCIATING\n")
      assert Wifi.connect("Hall", "", nil, "BE") == %{"ok" => false, "reason" => "rejected"}
    end

    test "no supplicant comes up: supplicant_failed" do
      Box.put("/sys/class/net/wlan0/operstate", "up\n")
      assert Wifi.connect("Hall", "", false, "BE") == %{"ok" => false, "reason" => "supplicant_failed"}
      assert ran?(["systemctl", "restart", "wpa_supplicant@wlan0.service"])
      assert Enum.any?(Box.ran(), &match?(["wpa_supplicant", "-B", "-s", "-i", "wlan0", "-c" | _], &1))
    end
  end

  describe "Wi-Fi scan" do
    test "no interface: a reason and the kernel lines, never a bare empty list" do
      runner(fn
        ["dmesg"] -> {0, "[ 1.0] brcmfmac: brcmf_sdio_htclk: HT Avail timeout\n[ 1.1] usb 1-1: new device\n"}
        _ -> nil
      end)

      r = json("/api/wifi/scan")
      assert r["available"] == false and r["networks"] == [] and r["reason"] == "no_interface"
      assert r["detail"] =~ "wlan0 is missing; trying modprobe brcmfmac"
      assert r["detail"] =~ "HT Avail timeout"
      refute r["detail"] =~ "usb 1-1"
      assert is_float(r["elapsed"])
      assert ran?(["modprobe", "brcmfmac"])
      d = json("/api/diag/scan")
      assert d["raw"] =~ ~r/^Wi-Fi scan test at \d\d:\d\d:\d\d: no_interface\n/
    end

    test "a scan through wpa_cli: strongest first, one entry per SSID, saved marked" do
      Box.put("/sys/class/net/wlan0/operstate", "up\n")
      Wifi.write_wpa("BE", [%{"ssid" => Wifi.hexify("Hall"), "psk" => nil, "hidden" => false, "prio" => 1}])

      results =
        "bssid / frequency / signal level / flags / ssid\n" <>
          "aa:bb:cc:00:00:01\t2412\t-70\t[WPA2-PSK-CCMP][ESS]\tHall\n" <>
          "aa:bb:cc:00:00:02\t5180\t-50\t[WPA2-PSK-CCMP][ESS]\tHall\n" <>
          "aa:bb:cc:00:00:03\t2437\t-60\t[ESS]\tCaf\\xc3\\xa9\n" <>
          "aa:bb:cc:00:00:04\t2437\t-40\t[ESS]\t\n" <>
          "aa:bb:cc:00:00:05\tx\t-40\t[ESS]\tBad\n"

      runner(fn
        ["wpa_cli", _, _, _, _, "ping"] -> {0, "PONG\n"}
        ["wpa_cli", _, _, _, _, "scan"] -> {0, "OK\n"}
        ["wpa_cli", _, _, _, _, "scan_results"] -> {0, results}
        ["wpa_cli", _, _, _, _, "status"] -> {0, "wpa_state=SCANNING\n"}
        _ -> nil
      end)

      r = json("/api/wifi/scan")
      assert r["available"] == true and r["source"] == "wpa"
      refute Map.has_key?(r, "reason")

      assert r["networks"] == [
               %{"ssid" => "Hall", "signal" => -50, "secured" => true, "band" => "5", "saved" => true},
               %{"ssid" => "Café", "signal" => -60, "secured" => false, "band" => "2.4", "saved" => false}
             ]

      assert Wifi.last_scan() =~ ~r/^Wi-Fi scan test at \d\d:\d\d:\d\d: 2 networks via wpa in /
    end

    test "parse_iw_scan" do
      out =
        "BSS aa:bb(on wlan0)\n\tfreq: 5180\n\tsignal: -48.00 dBm\n\tSSID: Hall\n\tRSN:\t * Version: 1\n" <>
          "BSS cc:dd(on wlan0)\n\tfreq: 2412\n\tsignal: -70.00 dBm\n\tSSID: Hall\n" <>
          "BSS ee:ff(on wlan0)\n\tfreq: 2412.0\n\tcapability: ESS Privacy\n\tSSID: Old\\x20Net\n" <>
          "BSS 00:11(on wlan0)\n\tSSID: \\x00\\x00\n" <>
          "BSS 00:12(on wlan0)\n\tSSID: \n"

      assert Wifi.parse_iw_scan(out) == [
               %{"ssid" => "Hall", "signal" => -48, "secured" => true, "band" => "5"},
               %{"ssid" => "Old Net", "signal" => -90, "secured" => true, "band" => "2.4"}
             ]
    end

    test "while the hotspot is on: the AP-mode scan, without the box's own hotspot" do
      Box.put("/run/alnasl-hotspot/active", "")
      Box.put("/usr/sbin/iw", "")
      File.chmod!(Sys.path("/usr/sbin/iw"), 0o755)

      runner(fn
        ["iw", "dev", "wlan0", "scan", "ap-force"] ->
          {0,
           "BSS 1\n\tfreq: 2412\n\tsignal: -30 dBm\n\tSSID: Alnasl-setup-1234\nBSS 2\n\tfreq: 2412\n\tsignal: -60 dBm\n\tSSID: Hall\n"}

        _ ->
          nil
      end)

      if Sys.have?("iw") do
        r = json("/api/wifi/scan")
        assert r["source"] == "iw-ap" and r["hotspot"] == true and r["age"] == 0
        assert [%{"ssid" => "Hall", "saved" => false}] = r["networks"]
      end
    end

    test "while the hotspot is on and the chip cannot scan: the saved list from before" do
      Box.put("/run/alnasl-hotspot/active", "")
      t = Sys.now() - 30

      Box.put(
        "/run/alnasl-hotspot/scan.json",
        Json.encode(%{
          "t" => t,
          "networks" => [
            %{"ssid" => "Weak", "signal" => -80, "secured" => true, "band" => "2.4"},
            %{"ssid" => "Strong", "signal" => -40, "secured" => false, "band" => "5"},
            %{"nonsense" => 1},
            "x"
          ]
        })
      )

      r = json("/api/portal/scan")
      assert r["source"] == "cached" and r["hotspot"] == true and r["available"] == true
      assert r["age"] in 29..32
      assert Enum.map(r["networks"], & &1["ssid"]) == ["Strong", "Weak"]
      assert Enum.all?(r["networks"], &(&1["saved"] == false))
    end

    test "while the hotspot is on and nothing is known: no_results" do
      Box.put("/run/alnasl-hotspot/active", "")
      r = json("/api/wifi/scan")
      assert r["networks"] == [] and r["reason"] == "no_results" and r["source"] == "cached"
    end
  end

  # ------------------------------------------------------------------------------------- network --

  describe "network settings" do
    test "validate_static: Python's ipaddress rules" do
      assert Net.validate_static(%{
               "address" => "192.168.1.50/24",
               "gateway" => " 192.168.1.1 ",
               "dns" => "1.1.1.1, 8.8.8.8"
             }) ==
               {"192.168.1.50/24", "192.168.1.1", ["1.1.1.1", "8.8.8.8"]}

      assert Net.validate_static(%{"address" => "10.0.0.5/255.255.0.0"}) == {"10.0.0.5/16", "", []}

      prefix = "Enter an IPv4 address with a prefix, such as 192.168.1.50/24."

      for a <- ["192.168.1.50", "192.168.1.50/32", "10.0.0.5/0", "fe80::1/64"] do
        assert_raise ArgumentError, prefix, fn -> Net.validate_static(%{"address" => a}) end
      end

      for a <- ["nope", "300.1.1.1/24", "1.2.3/24", "01.2.3.4/24", "1.2.3.4/33", ""] do
        assert_raise ArgumentError, "'#{a}' does not appear to be an IPv4 or IPv6 interface", fn ->
          Net.validate_static(%{"address" => a})
        end
      end

      assert_raise ArgumentError, "The gateway must be an address inside the same network.", fn ->
        Net.validate_static(%{"address" => "192.168.1.50/24", "gateway" => "192.168.2.1"})
      end

      assert_raise ArgumentError, "'gw' does not appear to be an IPv4 or IPv6 address", fn ->
        Net.validate_static(%{"address" => "192.168.1.50/24", "gateway" => "gw"})
      end

      assert_raise ArgumentError, "DNS servers must be IPv4 addresses.", fn ->
        Net.validate_static(%{"address" => "192.168.1.50/24", "dns" => "1.1.1.1 ::1"})
      end
    end

    test "a static address is written, applied, and reverted when nobody confirms" do
      r =
        ok!(
          post("/api/net/set", %{
            "iface" => "eth0",
            "mode" => "static",
            "address" => "192.168.1.50/24",
            "gateway" => "192.168.1.1",
            "dns" => "1.1.1.1 9.9.9.9"
          })
        )

      assert r == %{"ok" => true, "confirm_seconds" => 1}
      f = "/etc/systemd/network/10-wired.network.d/50-alnasl.conf"

      assert Sys.read(f) ==
               "[Network]\nDHCP=no\nAddress=192.168.1.50/24\nGateway=192.168.1.1\nDNS=1.1.1.1\nDNS=9.9.9.9\n"

      assert ran?(["networkctl", "reload"]) and ran?(["networkctl", "reconfigure", "eth0"])

      assert json("/api/net")["eth0"]["config"] == %{
               "mode" => "static",
               "address" => "192.168.1.50/24",
               "gateway" => "192.168.1.1",
               "dns" => ["1.1.1.1", "9.9.9.9"]
             }

      wait_until(fn -> not Sys.exists?(f) end, 4000)
      refute Sys.exists?(f)
    end

    test "dhcp removes the drop-in; confirmed, it stays removed" do
      f = "/etc/systemd/network/20-wireless.network.d/50-alnasl.conf"
      Box.put(f, "[Network]\nDHCP=no\nAddress=10.1.1.1/24\n")
      post("/api/net/set", %{"iface" => "wlan0", "mode" => "dhcp"})
      refute Sys.exists?(f)
      assert ok!(post("/api/net/confirm", %{"iface" => "wlan0"})) == %{"ok" => true}
      Process.sleep(1500)
      refute Sys.exists?(f)
      assert ok!(post("/api/net/confirm", %{"iface" => "wlan0"})) == %{"ok" => true}
    end

    test "a confirmed setting stays" do
      f = "/etc/systemd/network/10-wired.network.d/50-alnasl.conf"
      Box.put(f, "[Network]\nDHCP=no\nAddress=10.1.1.1/24\n")
      post("/api/net/set", %{"iface" => "eth0", "mode" => "static", "address" => "10.1.1.2/24"})
      post("/api/net/confirm", %{"iface" => "eth0"})
      Process.sleep(1500)
      assert Sys.read(f) =~ "10.1.1.2/24"
    end

    test "an unconfirmed change brings back the previous file" do
      f = "/etc/systemd/network/10-wired.network.d/50-alnasl.conf"
      Box.put(f, "[Network]\nDHCP=no\nAddress=10.1.1.1/24\n")
      post("/api/net/set", %{"iface" => "eth0", "mode" => "static", "address" => "10.1.1.2/24"})
      wait_until(fn -> Sys.read(f) =~ "10.1.1.1/24" end, 4000)
      assert Sys.read(f) == "[Network]\nDHCP=no\nAddress=10.1.1.1/24\n"
    end

    test "bad requests" do
      assert post("/api/net/set", %{"iface" => "eth1", "mode" => "dhcp"}).json == %{"error" => "bad interface"}
      r = post("/api/net/set", %{"iface" => "eth0", "mode" => "static", "address" => "nope"})
      assert r.status == 400 and r.json == %{"error" => "'nope' does not appear to be an IPv4 or IPv6 interface"}
    end

    test "/api/net: addresses, gateway, the config, DNS; the hotspot's own address is not the hall's" do
      Box.put("/sys/class/net/eth0/carrier", "1\n")
      Box.put("/sys/class/net/eth0/address", "dc:a6:32:00:00:01\n")
      Box.put("/sys/class/net/wlan0/address", "dc:a6:32:00:00:02\n")
      Box.put("/run/alnasl-hotspot/active", "")
      Box.put("/run/alnasl-hotspot/status.json", ~s({"ssid": "Alnasl-setup-AB12"}))

      runner(fn
        ["ip", "-j", "-4", "addr", "show", "eth0"] ->
          {0, ~s([{"addr_info": [{"local": "192.168.1.9", "prefixlen": 24}]}])}

        ["ip", "-j", "-4", "addr", "show", "wlan0"] ->
          {0, ~s([{"addr_info": [{"local": "10.42.0.1", "prefixlen": 24}]}])}

        ["ip", "-j", "route", "show", "default", "dev", "eth0"] ->
          {0, ~s([{"dst": "default", "gateway": "192.168.1.1"}])}

        ["ip", "-j", "route", "show", "default", "dev", "wlan0"] ->
          {0, ~s([{"gateway": "10.42.0.254"}])}

        ["resolvectl", "dns"] ->
          {0, "Global: 1.1.1.1\nLink 2 (eth0): 192.168.1.1 1.1.1.1 fe80::1\n"}

        _ ->
          nil
      end)

      n = json("/api/net")

      assert n["eth0"] == %{
               "present" => true,
               "link" => true,
               "addresses" => ["192.168.1.9/24"],
               "gateway" => "192.168.1.1",
               "config" => %{"mode" => "dhcp"},
               "mac" => "dc:a6:32:00:00:01"
             }

      assert n["wlan0"]["addresses"] == [] and n["wlan0"]["gateway"] == nil
      assert n["wlan0"]["hotspot"] == "Alnasl-setup-AB12" and n["wlan0"]["link"] == false
      assert n["dns"] == ["1.1.1.1", "192.168.1.1"]
      assert n["hostname"] == hostname()
    end

    test "/api/net: a connected Wi-Fi says its SSID and RSSI" do
      Box.put("/sys/class/net/wlan0/carrier", "1\n")

      runner(fn
        ["wpa_cli", _, _, _, _, "status"] -> {0, "wpa_state=COMPLETED\nssid=Hall\\x20A\n"}
        ["wpa_cli", _, _, _, _, "signal_poll"] -> {0, "RSSI=-51\nLINKSPEED=72\n"}
        _ -> nil
      end)

      w = json("/api/net")["wlan0"]
      assert w["ssid"] == "Hall A" and w["rssi"] == "-51"

      assert json("/api/net")["eth0"] == %{
               "present" => false,
               "link" => false,
               "addresses" => [],
               "gateway" => nil,
               "config" => %{"mode" => "dhcp"},
               "mac" => ""
             }
    end

    test "hostname" do
      assert ok!(post("/api/hostname", %{"hostname" => " Hall-Box1 "})) == %{"ok" => true, "hostname" => "hall-box1"}
      assert Sys.read("/etc/hostname") == "hall-box1\n"
      assert ran?(["hostname", "hall-box1"])
      assert post("/api/hostname", %{"hostname" => "-x"}).status == 400
      assert post("/api/hostname", %{"hostname" => String.duplicate("a", 33)}).status == 400
    end
  end

  defp wait_until(fun, ms) do
    cond do
      fun.() -> :ok
      ms <= 0 -> :timeout
      true -> Process.sleep(50) && wait_until(fun, ms - 50)
    end
  end

  # ---------------------------------------------------------------------------- services / mode --

  describe "services, mode, finish, power" do
    test "services: kiosk off now, stop afterwards; no ssh or tailscale switch" do
      r = ok!(post("/api/services", %{"kiosk" => false, "ssh" => true, "tailscale" => true}))
      assert Map.keys(r) |> Enum.sort() == ["alnasl", "kiosk"]
      assert ran?(["systemctl", "disable", "alnasl-kiosk.service"])
      assert ran?(["systemctl", "stop", "--no-block", "alnasl-kiosk.service"])
      refute Enum.any?(Box.ran(), &(Enum.join(&1, " ") =~ ~r/ssh|tailscale/))
      post("/api/services", %{"alnasl" => 1})
      assert ran?(["systemctl", "enable", "alnasl.service", "alnasl-update.path"])
      assert ran?(["systemctl", "start", "--no-block", "alnasl.service", "alnasl-update.path"])
      post("/api/services", %{"alnasl" => false, "kiosk" => true})
      assert ran?(["systemctl", "disable", "alnasl.service", "alnasl-update.path"])
      assert ran?(["systemctl", "enable", "alnasl-kiosk.service"])
    end

    test "mode: the rules of a switch" do
      assert post("/api/mode", %{"mode" => "slave"}).json == %{"error" => "Not confirmed."}
      assert post("/api/mode", %{"mode" => "root", "confirm" => "SWITCH"}).json == %{"error" => "bad_mode"}
      assert Sys.read("/var/lib/alnasl-setup/mode") == ""

      assert ok!(post("/api/mode", %{"mode" => "alnasl", "confirm" => "SWITCH"})) ==
               %{"ok" => true, "mode" => "master", "role" => "alnasl", "same" => true}

      assert ok!(post("/api/mode", %{"mode" => "slave", "confirm" => "SWITCH"})) ==
               %{"ok" => true, "mode" => "slave", "role" => "arkab", "same" => false}

      assert Sys.read("/var/lib/alnasl-setup/mode") == "arkab\n"
      assert Sys.read("/run/alnasl-screen/state") == "reboot\n"
      assert ran?(["systemctl", "reboot", "--no-block"])

      m = json("/api/mode")
      assert m["mode"] == "slave" and m["role"] == "arkab" and m["set"] == true
      assert m["running"] == "slave" and m["running_role"] == "arkab"

      assert ok!(post("/api/mode", %{"mode" => "POLIS ", "confirm" => "SWITCH"}))["role"] == "polis"
    end

    test "finish: the role chosen in the wizard is written at the end; another role reboots" do
      Box.put("/run/alnasl-mode/role", "alnasl\n")
      assert ok!(post("/api/finish", %{"mode" => "arkab"})) == %{"ok" => true, "reboot" => true}
      assert Sys.read("/var/lib/alnasl-setup/done") == "1\n"
      assert Sys.read("/var/lib/alnasl-setup/mode") == "arkab\n"
      assert ran?(["systemctl", "reboot", "--no-block"])
      assert post("/api/finish", %{"mode" => true}).json == %{"error" => "bad_mode"}
    end

    test "finish without a role change restarts the kiosk; reopen undoes done" do
      runner(fn
        ["systemctl", "is-enabled", "alnasl-kiosk.service"] -> {0, "enabled\n"}
        _ -> nil
      end)

      assert ok!(post("/api/finish", %{})) == %{"ok" => true}
      assert ran?(["systemctl", "restart", "--no-block", "alnasl-kiosk.service"])
      assert json("/api/state")["done"] == true
      assert ok!(post("/api/reopen", %{})) == %{"ok" => true}
      assert json("/api/state")["done"] == false
    end

    test "power and reset" do
      assert post("/api/power", %{"action" => "halt"}).json == %{"error" => "bad action"}
      assert ok!(post("/api/power", %{"action" => "poweroff"})) == %{"ok" => true}
      assert Sys.read("/run/alnasl-screen/state") == "shutdown\n"
      assert ran?(["systemctl", "poweroff", "--no-block"])
      assert post("/api/reset", %{"confirm" => "yes"}).json == %{"error" => "Not confirmed."}
      assert ok!(post("/api/reset", %{"confirm" => "RESET"})) == %{"ok" => true}
      assert Sys.read("/run/alnasl-screen/state") == "reset-1\n"
      assert ran?(["systemctl", "start", "--no-block", "alnasl-reset.service"])
    end

    test "console and screen" do
      assert ok!(post("/api/console/show", %{})) == %{"ok" => true}
      assert ran?(["chvt", "2"])
      Box.put("/dev/tty1", "")
      assert ok!(post("/api/screen/stop", %{})) == %{"ok" => true}
      assert ran?(["systemctl", "stop", "alnasl-kiosk.service"]) and ran?(["chvt", "1"])
      assert Sys.read("/dev/tty1") =~ "alnasl-screen start"
    end
  end

  # ------------------------------------------------------------------------------ printers/sound --

  describe "printers" do
    defp cups(extra \\ fn _ -> nil end) do
      runner(fn argv ->
        extra.(argv) ||
          case argv do
            ["lpstat", "-d"] ->
              {0, "system default destination: hall\n"}

            ["lpstat", "-v"] ->
              {0,
               "device for hall: ipp://user:pw@10.0.0.9/ipp/print?x=1\ndevice for usb1: usb://HP/LaserJet?serial=12\n"}

            ["lpstat", "-p"] ->
              {0, "printer hall is idle.  enabled since Sat\nprinter usb1 disabled since Sat -\n\treason\n"}

            ["lpinfo" | _] ->
              {0, "network ipp\ndirect usb://HP/LaserJet?serial=12\ndirect usb://Brother/HL?serial=9\n"}

            _ ->
              nil
          end
      end)
    end

    test "listed anywhere, the address without credentials or query" do
      cups()

      assert json("/api/printers") == %{
               "printers" => [
                 %{"name" => "hall", "uri" => "ipp://10.0.0.9/ipp/print", "default" => true, "state" => "idle"},
                 %{"name" => "usb1", "uri" => "usb://HP/LaserJet", "default" => false, "state" => "disabled"}
               ],
               "cups" => false
             }

      assert json("/api/printers/usb") == %{"usb" => ["usb://HP/LaserJet?serial=12", "usb://Brother/HL?serial=9"]}
    end

    test "changed only on a Polis box" do
      cups()
      r = post("/api/printers/add", %{"name" => "hall", "uri" => "ipp://10.0.0.9/ipp/print"})
      assert r.status == 400 and r.json == %{"error" => "not_polis"}
    end

    test "add by address, by USB; default, remove, test page" do
      Box.put("/run/alnasl-mode/role", "polis\n")
      cups()
      assert %{"printers" => [_, _]} = ok!(post("/api/printers/add", %{"address" => "10.0.0.20"}))
      assert ran?(["lpadmin", "-p", "10-0-0-20", "-E", "-v", "ipp://10.0.0.20/ipp/print", "-m", "everywhere"])
      refute ran?(["lpadmin", "-d", "10-0-0-20"])
      ok!(post("/api/printers/add", %{"usb" => "usb://Brother/HL?serial=9", "name" => "Office_1"}))
      assert ran?(["lpadmin", "-p", "Office_1", "-E", "-v", "usb://Brother/HL?serial=9", "-m", "raw"])
      assert post("/api/printers/add", %{"usb" => "usb://Other/X"}).json == %{"error" => "bad_printer_address"}
      assert post("/api/printers/add", %{"address" => "a b"}).json == %{"error" => "bad_printer_address"}

      assert post("/api/printers/add", %{"address" => "10.0.0.2", "name" => "bad name"}).json == %{
               "error" => "bad_printer_name"
             }

      ok!(post("/api/printers/default", %{"name" => "usb1"}))
      assert ran?(["lpadmin", "-d", "usb1"])
      assert post("/api/printers/default", %{"name" => "ghost"}).json == %{"error" => "bad_printer_name"}
      ok!(post("/api/printers/remove", %{"name" => "usb1"}))
      assert ran?(["lpadmin", "-x", "usb1"])

      assert ok!(post("/api/printers/test", %{"name" => "hall"})) == %{"ok" => true}
      assert ran?(["lp", "-d", "hall", "-t", "Alnasl test page", "-o", "media=A4", "/run/alnasl-setup-testpage.pdf"])
      assert Sys.read("/run/alnasl-setup-testpage.pdf") =~ ~r/^%PDF-1.4\n/
    end

    test "the first printer becomes the default; a failed lpadmin is reported" do
      Box.put("/run/alnasl-mode/role", "polis\n")

      runner(fn
        ["lpadmin", "-p", "bad" | _] -> {1, ""}
        _ -> nil
      end)

      ok!(post("/api/printers/add", %{"address" => "10.0.0.20", "name" => "first"}))
      assert ran?(["lpadmin", "-d", "first"])

      assert post("/api/printers/add", %{"address" => "10.0.0.21", "name" => "bad"}).json == %{
               "error" => "printer_not_added"
             }

      runner(fn
        ["lp" | _] -> {1, ""}
        ["lpstat", "-p"] -> {0, "printer hall is idle.\n"}
        _ -> nil
      end)

      assert post("/api/printers/test", %{"name" => "hall"}).json == %{"error" => "printer_test_failed"}
    end

    test "the test page is a well-formed one-page PDF" do
      pdf = AlnaslSetup.Server.Printers.test_pdf("Alnasl - test (page)", "Café\\x")
      assert String.starts_with?(pdf, "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
      assert pdf =~ "(Alnasl - test \\(page\\)) Tj"
      assert pdf =~ "(Caf?\\\\x) Tj"
      [_, xref] = Regex.run(~r/startxref\n(\d+)\n%%EOF\n$/, pdf)
      xref = String.to_integer(xref)
      assert binary_part(pdf, xref, 6) == "xref\n0"
      offs = Regex.scan(~r/^(\d{10}) 00000 n $/m, pdf) |> Enum.map(fn [_, o] -> String.to_integer(o) end)
      assert length(offs) == 5

      for {o, i} <- Enum.with_index(offs, 1) do
        assert binary_part(pdf, o, byte_size("#{i} 0 obj")) == "#{i} 0 obj"
      end

      assert pdf =~ "trailer\n<< /Size 6 /Root 1 0 R >>\n"
      [_, len] = Regex.run(~r/<< \/Length (\d+) >>\nstream\n/, pdf)
      [_, content] = Regex.run(~r/stream\n(.*)\nendstream/s, pdf)
      assert byte_size(content) == String.to_integer(len)
    end
  end

  describe "sound" do
    test "read anywhere, set only on a Nunki box" do
      runner(fn
        ["/usr/local/sbin/alnasl-sound", "--cards"] -> {0, "hdmi jack usb\n"}
        _ -> nil
      end)

      assert json("/api/sound") == %{"outputs" => ["hdmi", "jack"], "output" => "hdmi", "volume" => 80}
      r = post("/api/sound", %{"output" => "jack", "volume" => 50})
      assert r.status == 400 and r.json == %{"error" => "not_nunki"}
      Box.put("/run/alnasl-mode/role", "nunki\n")
      assert ok!(post("/api/sound", %{"output" => "jack", "volume" => "50"}))["volume"] == 50
      assert Sys.read("/var/lib/alnasl-setup/sound.conf") == "OUTPUT=jack\nVOLUME=50\n"
      assert ran?(["/usr/local/sbin/alnasl-sound"])
      assert json("/api/sound")["output"] == "jack"
      assert post("/api/sound", %{"output" => "usb"}).json == %{"error" => "bad_output"}
      assert post("/api/sound", %{"volume" => 101}).json == %{"error" => "bad_volume"}
      assert post("/api/sound", %{"volume" => "loud"}).json == %{"error" => "bad_volume"}
      assert post("/api/sound", %{"volume" => nil}).json == %{"error" => "bad_volume"}
      assert ok!(post("/api/sound/test", %{})) == %{"ok" => true}
      assert ran?(["/usr/local/sbin/alnasl-sound", "--test", "en", "This is the announcer. One, two, three."])
    end

    test "a sound.conf with nonsense falls back" do
      Box.put("/var/lib/alnasl-setup/sound.conf", "OUTPUT=spdif\nVOLUME=900\n")
      assert json("/api/sound") == %{"outputs" => [], "output" => "hdmi", "volume" => 80}
    end
  end

  # ------------------------------------------------------------------------------------ get help --

  describe "get help" do
    test "the address: https only, no credentials; empty puts the default back" do
      assert json("/api/help") == %{
               "url" => "https://alnasl.zerotwo.cloud/support/upload",
               "default_url" => "https://alnasl.zerotwo.cloud/support/upload",
               "last" => nil
             }

      for bad <- [
            "http://x.example/u",
            "https://user@x.example/u",
            "https://u:p@x.example/",
            "https:///nohost",
            "https://x.example/#frag",
            "https://x.example:99999/",
            "https://x.example:abc/",
            "https://x .example/",
            "ftp://x.example/",
            "https://x.example/" <> String.duplicate("a", 300)
          ] do
        assert post("/api/help/url", %{"url" => bad}).json == %{"error" => "bad_url"}, bad
      end

      assert ok!(post("/api/help/url", %{"url" => "https://help.example:8443/up?x=1"}))["url"] ==
               "https://help.example:8443/up?x=1"

      assert state_json()["support_url"] == "https://help.example:8443/up?x=1"
      assert ok!(post("/api/help/url", %{"url" => ""}))["url"] == "https://alnasl.zerotwo.cloud/support/upload"
      assert state_json()["support_url"] == ""
    end

    test "a bad stored address falls back to the default" do
      Box.put("/var/lib/alnasl-setup/state.json", ~s({"support_url": "http://evil.example/"}))
      assert json("/api/help")["url"] == "https://alnasl.zerotwo.cloud/support/upload"
    end

    test "the last code, only while it is valid" do
      Box.put(
        "/var/lib/alnasl-setup/state.json",
        ~s({"help_last": {"code": "123456", "expires_at": "2999-01-01T00:00:00Z", "sent_at": "x"}})
      )

      assert json("/api/help")["last"] == %{"code" => "123456", "expires_at" => "2999-01-01T00:00:00Z"}

      Box.put(
        "/var/lib/alnasl-setup/state.json",
        ~s({"help_last": {"code": "123456", "expires_at": "2001-01-01T00:00:00"}})
      )

      assert json("/api/help")["last"] == nil
      Box.put("/var/lib/alnasl-setup/state.json", ~s({"help_last": {"code": "123456", "expires_at": "soon"}}))
      assert json("/api/help")["last"] == nil
    end

    # a support server on loopback (plain HTTP through the test-only :help_url seam)
    defp support_server(reply) do
      parent = self()
      id = {:support, System.unique_integer()}

      handler = fn r ->
        send(parent, {:upload, r})
        reply.(r)
      end

      {:ok, pid} = Http.start_link(id: id, ip: {127, 0, 0, 1}, port: 0, handler: handler, max_body: 3_000_000)
      on_exit(fn -> Process.exit(pid, :kill) end)
      Application.put_env(:alnasl_setup, :help_url, "http://127.0.0.1:#{Http.port(id)}/support/upload")
    end

    test "sent: the code comes back and is kept" do
      support_server(fn _ -> {201, [], %{"code" => "042424", "expires_at" => "2999-01-01T00:00:00Z"}} end)
      Box.put("/proc/device-tree/serial-number", "10000000abcdef12\0")
      Box.put("/etc/alnasl/image-version", "7.2\n")
      Box.put("/opt/alnasl/current/VERSION", "1.4.0\n")

      assert ok!(post("/api/help/send", %{})) == %{
               "ok" => true,
               "code" => "042424",
               "expires_at" => "2999-01-01T00:00:00Z"
             }

      assert_received {:upload, r}
      assert r.method == "POST" and r.path == "/support/upload"
      assert r.headers["content-type"] == "text/plain; charset=utf-8"
      assert r.headers["user-agent"] == "alnasl-box-help"
      assert r.headers["x-alnasl-box"] == "cdef12"
      assert r.headers["x-alnasl-version"] == "1.4.0/7.2"
      assert r.headers["x-alnasl-mode"] == "alnasl"
      assert r.body =~ "ALNASL HALL BOX DIAGNOSTICS"
      assert %{"code" => "042424", "sent_at" => _} = state_json()["help_last"]
      assert json("/api/help")["last"]["code"] == "042424"
    end

    test "refusals and odd answers" do
      for {status, key} <- [
            {404, "support_off"},
            {413, "too_large"},
            {429, "rate_limited"},
            {400, "rejected"},
            {415, "rejected"},
            {500, "server_error"},
            {302, "server_error"}
          ] do
        support_server(fn _ -> {status, [{"Location", "http://elsewhere.example/"}], %{"error" => "x"}} end)
        assert ok!(post("/api/help/send", %{})) == %{"ok" => false, "error" => key, "status" => status}
      end

      support_server(fn _ -> {201, [], %{"code" => "12345", "expires_at" => "x"}} end)
      assert ok!(post("/api/help/send", %{})) == %{"ok" => false, "error" => "server_error", "status" => 201}
      support_server(fn _ -> {200, [], %{"code" => "123456", "expires_at" => "x"}} end)
      assert ok!(post("/api/help/send", %{})) == %{"ok" => false, "error" => "server_error", "status" => 200}
      support_server(fn _ -> {201, [{"Content-Type", "text/plain"}], "not json"} end)
      assert ok!(post("/api/help/send", %{})) == %{"ok" => false, "error" => "server_error", "status" => 201}
    end

    test "nobody answers: no_internet" do
      {:ok, ls} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, p} = :inet.port(ls)
      :gen_tcp.close(ls)
      Application.put_env(:alnasl_setup, :help_url, "http://127.0.0.1:#{p}/support/upload")
      assert ok!(post("/api/help/send", %{})) == %{"ok" => false, "error" => "no_internet"}
    end

    test "the body is cut at 2,000,000 bytes on a character boundary" do
      body = AlnaslSetup.Server.Help.cut(String.duplicate("é", 1_000_001))
      assert byte_size(body) == 2_000_000 and String.valid?(body)
      body = AlnaslSetup.Server.Help.cut("a" <> String.duplicate("é", 1_000_000))
      assert byte_size(body) == 1_999_999 and String.valid?(body)
      assert AlnaslSetup.Server.Help.cut("short") == "short"
    end
  end

  # ----------------------------------------------------------------------------- system updates --

  describe "system updates" do
    defp sysupd(s), do: Application.put_env(:alnasl_setup, :fake_sysupd, s)

    test "the status as the updater gives it; unavailable when it cannot" do
      assert json("/api/system") == %{"ab" => false, "error" => "unavailable"}
      sysupd(%{"ab" => true, "train" => "v7", "updates_on" => true, "busy" => false, "trial" => false})
      assert json("/api/system")["train"] == "v7"
      sysupd([1, 2])
      assert json("/api/system") == %{"ab" => false, "error" => "unavailable"}
    end

    test "the rules of a request" do
      sysupd(%{"ab" => false})
      assert post("/api/system/install", %{"confirm" => "INSTALL"}).json == %{"error" => "not_ab"}
      sysupd(%{"ab" => true, "updates_on" => false})
      assert post("/api/system/install", %{"confirm" => "INSTALL"}).json == %{"error" => "updates_off"}
      sysupd(%{"ab" => true, "updates_on" => true, "busy" => true})
      assert post("/api/system/install", %{"confirm" => "INSTALL"}).json == %{"error" => "busy"}
      sysupd(%{"ab" => true, "updates_on" => true, "trial" => true})
      assert post("/api/system/install", %{"confirm" => "INSTALL"}).json == %{"error" => "busy"}
      sysupd(%{"ab" => true, "updates_on" => true, "train" => "v7"})
      assert post("/api/system/install", %{"confirm" => "yes"}).json == %{"error" => "Not confirmed."}

      assert post("/api/system/upgrade", %{"confirm" => "INSTALL", "train" => "v8"}).json == %{
               "error" => "Not confirmed."
             }

      assert post("/api/system/upgrade", %{"confirm" => "UPGRADE", "train" => "v7"}).json == %{"error" => "bad_train"}
      assert post("/api/system/upgrade", %{"confirm" => "UPGRADE", "train" => "8"}).json == %{"error" => "bad_train"}

      assert post("/api/system/upgrade", %{"confirm" => "UPGRADE", "train" => "v1000"}).json == %{
               "error" => "bad_train"
             }

      refute Sys.exists?("/var/lib/alnasl-os-update/system/request")

      assert ok!(post("/api/system/upgrade", %{"confirm" => "UPGRADE", "train" => "v8", "by" => "arkab"})) == %{
               "ok" => true
             }

      assert Sys.read("/var/lib/alnasl-os-update/system/request") ==
               ~s({"action": "upgrade", "by": "arkab", "train": "v8"}\n)

      assert ran?(["systemctl", "start", "--no-block", "alnasl-system-update.service"])

      assert ok!(post("/api/system/install", %{"confirm" => "INSTALL", "by" => "evil"})) == %{"ok" => true}
      assert Sys.read("/var/lib/alnasl-os-update/system/request") == ~s({"action": "install", "by": "menu"}\n)
    end

    @tag :unix
    test "the request file is 0600" do
      sysupd(%{"ab" => true, "updates_on" => true, "train" => "v7"})
      ok!(post("/api/system/install", %{"confirm" => "INSTALL"}))
      assert mode_of("/var/lib/alnasl-os-update/system/request") == 0o600
    end

    test "check and the update address" do
      assert ok!(post("/api/system/check", %{})) == %{"ok" => true}
      assert ran?(["systemctl", "start", "--no-block", "alnasl-system-update-check.service"])
      assert post("/api/system/url", %{"url" => "http://x.example/"}).json == %{"error" => "bad_url"}
      assert post("/api/system/url", %{"url" => "https://u@x.example/"}).json == %{"error" => "bad_url"}
      sysupd(%{"ab" => true})
      assert ok!(post("/api/system/url", %{"url" => " https://upd.example/v7 "})) == %{"ab" => true}
      assert state_json()["update_url"] == "https://upd.example/v7"
    end
  end

  # ------------------------------------------------------------------------- hotspot and portal --

  describe "the setup hotspot and its portal" do
    test "/api/hotspot: the password only while the hotspot is on" do
      Box.put("/boot/efi/alnasl-hotspot.txt", "password=hallpass99\n")

      assert json("/api/hotspot") == %{
               "active" => false,
               "ssid" => nil,
               "portal" => "http://10.42.0.1/",
               "reason" => nil,
               "starts_at" => nil
             }

      Box.put("/run/alnasl-hotspot/active", "")
      Box.put("/run/alnasl-hotspot/status.json", ~s({"ssid": "Alnasl-setup-AB12", "reason": "no_network"}))

      assert json("/api/hotspot") == %{
               "active" => true,
               "ssid" => "Alnasl-setup-AB12",
               "portal" => "http://10.42.0.1/",
               "reason" => "no_network",
               "starts_at" => nil,
               "password" => "hallpass99"
             }

      Box.put("/boot/efi/alnasl-hotspot.txt", "password=short\n")
      assert json("/api/hotspot")["password"] == nil
    end

    test "/api/theme: dark or light for the whole box, anything else leaves it be" do
      assert json("/api/state")["theme"] == "dark"
      assert post("/api/theme", %{"theme" => "light"}).json == %{"ok" => true}
      assert json("/api/state")["theme"] == "light"
      post("/api/theme", %{"theme" => "neon"})
      assert json("/api/state")["theme"] == "light"
    end

    test "/api/hotspot/start: the screen's start-it-now leaves a request for the daemon, the portal does not pass it" do
      assert post("/api/hotspot/start", %{}).json == %{"ok" => true}
      assert File.read!(Sys.path("/run/alnasl-hotspot/start")) == "1"
      assert AlnaslSetup.Hotspot.take_start()
      refute AlnaslSetup.Hotspot.take_start()
    end

    test "/api/portal: what the phone page shows, no secrets" do
      Box.put("/run/alnasl-hotspot/active", "")

      Box.put(
        "/run/alnasl-hotspot/status.json",
        ~s({"ssid": "Alnasl-setup-AB12", "reason": "no_network", "last_join": {"ok": false}})
      )

      Wifi.write_wpa("NL", [%{"ssid" => Wifi.hexify("Old"), "psk" => @ieee_psk, "hidden" => false, "prio" => 1}])

      runner(fn
        ["ip", "-j", "-4", "addr", "show", "eth0"] ->
          {0, ~s([{"addr_info": [{"local": "192.168.5.5", "prefixlen": 24}]}])}

        ["ip", "-j", "-4", "addr", "show", "wlan0"] ->
          {0, ~s([{"addr_info": [{"local": "10.42.0.1", "prefixlen": 24}]}])}

        _ ->
          nil
      end)

      p = json("/api/portal")
      h = hostname()

      assert p == %{
               "role" => "alnasl",
               "hostname" => h,
               "addresses" => [%{"iface" => "eth0", "ip" => "192.168.5.5"}],
               "next" => %{"host" => h, "mdns" => h <> ".local", "port" => 4040, "url" => "http://#{h}.local:4040/"},
               "hotspot" => %{"active" => true, "ssid" => "Alnasl-setup-AB12", "reason" => "no_network"},
               "last_join" => %{"ok" => false},
               "country" => "NL",
               "lang" => "en",
               "saved" => [%{"ssid" => "Old", "secured" => true, "hidden" => false}]
             }

      refute p |> Json.encode() |> String.contains?(@ieee_psk)
      Box.put("/run/alnasl-mode/role", "polis\n")
      assert json("/api/portal")["next"]["url"] == nil
      Box.put("/run/alnasl-mode/role", "arkab\n")
      assert json("/api/portal")["arkab"] == %{"up" => false, "pending" => false, "last" => nil}
    end

    test "/api/portal/join: validated, then handed to the hotspot daemon" do
      assert post("/api/portal/join", %{"ssid" => "", "passphrase" => "x"}).json == %{
               "error" => "The network name must be 1 to 32 bytes."
             }

      Box.put("/run/alnasl-hotspot/active", "")
      Box.put("/run/alnasl-hotspot/status.json", ~s({"ssid": "Alnasl-setup-AB12"}))
      r = ok!(post("/api/portal/join", %{"ssid" => "Hall", "passphrase" => "hallpass1", "country" => "be"}))
      assert r["ok"] == true and r["switching"] == true and r["ssid"] == "Hall" and r["hotspot"] == "Alnasl-setup-AB12"
      assert r["next"]["port"] == 4040
      assert Json.decode_or_nil(Sys.read("/run/alnasl-hotspot/join.json"))["country"] == "BE"
    end

    test "/api/portal/arkab-pin: the SD card file's rules" do
      assert post("/api/portal/arkab-pin", %{"pin" => "1234"}).json == %{"error" => "not_arkab"}
      Box.put("/run/alnasl-mode/role", "arkab\n")

      for {pin, err} <- [
            {"123", "pin_length"},
            {String.duplicate("1", 65), "pin_length"},
            {1234, "pin_length"},
            {" 1234", "pin_edges"},
            {"1234 ", "pin_edges"},
            {"'1234", "pin_edges"},
            {"1234\"", "pin_edges"},
            {"12\t34", "pin_control"},
            {"12\x7f34", "pin_control"},
            {"Remove", "pin_word"},
            {"VERWIJDEREN", "pin_word"}
          ] do
        assert post("/api/portal/arkab-pin", %{"pin" => pin}).json == %{"error" => err}, inspect(pin)
      end

      assert post("/api/portal/arkab-pin", %{"pin" => "12 34"}).json == %{"error" => "arkab_missing"}
    end

    @tag :unix
    test "/api/portal/arkab-pin: the request file for Arkab, 0600, Arkab's own, then Arkab restarts" do
      Box.put("/run/alnasl-mode/role", "arkab\n")
      File.mkdir_p!(Sys.path("/var/lib/arkab"))
      %{uid: uid, gid: gid} = File.stat!(Sys.path("/var/lib/arkab"))

      runner(fn
        ["getent", "passwd", "arkab"] -> {0, "arkab:x:#{uid}:#{gid}:Arkab:/var/lib/arkab:/sbin/nologin\n"}
        _ -> nil
      end)

      assert ok!(post("/api/portal/arkab-pin", %{"pin" => "12 34"})) == %{"ok" => true}
      assert Sys.read("/var/lib/arkab/pin-request") == "set\n12 34\n"
      st = File.stat!(Sys.path("/var/lib/arkab/pin-request"))
      assert Bitwise.band(st.mode, 0o777) == 0o600 and st.uid == uid and st.gid == gid
      assert ran?(["systemctl", "restart", "--no-block", "arkab.service"])
    end

    test "/api/portal/arkab-join: waits for a network, the hotspot daemon hands it over" do
      assert post("/api/portal/arkab-join", %{"link" => "x"}).json == %{"error" => "not_arkab"}
      Box.put("/run/alnasl-mode/role", "arkab\n")
      assert post("/api/portal/arkab-join", %{"link" => "https://evil.example/"}).json == %{"error" => "not_a_link"}
      Box.put("/var/lib/alnasl-setup/arkab-join.result", "{}")
      link = "https://arkab.example/join/ABCD"
      assert ok!(post("/api/portal/arkab-join", %{"link" => link})) == %{"ok" => true, "pending" => true}
      refute Sys.exists?("/var/lib/alnasl-setup/arkab-join.result")
      assert Server.arkab_pending_file() == "/var/lib/alnasl-setup/arkab-join.pending"
      assert %{"link" => ^link, "t" => t} = Json.decode_or_nil(Sys.read(Server.arkab_pending_file()))
      assert is_float(t)
      assert json("/api/portal")["arkab"]["pending"] == true

      # no network yet: stays
      assert Server.arkab_join_pending() == nil
      assert Sys.exists?(Server.arkab_pending_file())

      # a network and Arkab up: joined, the result kept for the page
      Application.put_env(:alnasl_setup, :connect_ports, %{4050 => listening_port()})

      runner(fn
        ["ip", "-j", "-4", "addr", "show", "eth0"] ->
          {0, ~s([{"addr_info": [{"local": "192.168.5.5", "prefixlen": 24}]}])}

        _ ->
          nil
      end)

      assert Server.arkab_join_pending() == "joined"
      refute Sys.exists?(Server.arkab_pending_file())

      assert %{"ok" => true, "reason" => "joined", "at" => _} =
               Json.decode_or_nil(Sys.read("/var/lib/alnasl-setup/arkab-join.result"))

      assert Server.arkab_join_pending() == nil

      # with a network now, the join is at once
      assert ok!(post("/api/portal/arkab-join", %{"link" => link})) == %{
               "ok" => true,
               "reason" => "joined",
               "pending" => false
             }
    end

    test "arkab_join_pending: an old link expires" do
      Box.put(
        "/var/lib/alnasl-setup/arkab-join.pending",
        Json.encode(%{"link" => "https://arkab.example/join/A", "t" => Sys.now() - 901})
      )

      assert Server.arkab_join_pending() == "expired"
      refute Sys.exists?("/var/lib/alnasl-setup/arkab-join.pending")

      assert %{"ok" => false, "reason" => "expired"} =
               Json.decode_or_nil(Sys.read("/var/lib/alnasl-setup/arkab-join.result"))
    end
  end

  # ------------------------------------------------------------------------ boot screen / sysinfo --

  describe "boot screen, boot log, system information" do
    test "/api/bootscreen" do
      b = json("/api/bootscreen")
      assert b == %{"state" => "", "lang" => "en", "alnasl_wanted" => false, "alnasl_up" => false, "role" => "alnasl"}
      assert Sys.exists?("/run/alnasl-kiosk/painted")
      Box.put("/run/alnasl-screen/state", "update-os\n")
      Box.put("/run/alnasl-screen/value", "37%\n")
      Box.put("/run/alnasl-screen/progress", "37\n")
      b = json("/api/bootscreen")
      assert b["state"] == "update-os" and b["value"] == "37%" and b["progress"] == 37

      assert b["geom"] == %{
               "adv" => %{"a" => 20},
               "names" => %{"a" => "a"},
               "height" => 40,
               "sub_y" => 300,
               "dots_y" => 346,
               "bar_w" => 360,
               "bar_h" => 6,
               "bar_steps_y" => 380,
               "with_steps" => ["update-os"]
             }

      Box.put("/run/alnasl-screen/value", "<script>\n")
      Box.put("/run/alnasl-screen/progress", "101\n")
      b = json("/api/bootscreen")
      assert b["value"] == "" and b["progress"] == nil
      Box.put("/run/alnasl-screen/state", "nonsense\n")
      assert json("/api/bootscreen")["state"] == ""
    end

    test "/api/bootlog: the lines after N, the status line, the layout on the first ask" do
      wait_until(fn -> json("/api/bootlog?after=0")["seq"] == 2 end, 3000)
      b = json("/api/bootlog?after=0")
      assert Enum.sort(Map.keys(b)) == ["lines", "ready", "seq", "status", "view"]
      assert b["status"] == "status in en" and b["ready"] == true

      assert b["lines"] == [
               %{"n" => 1, "t" => "kernel", "c" => "kernel", "e" => false, "m" => "line one"},
               %{"n" => 2, "t" => "alnasl", "c" => "app", "e" => true, "m" => "line two"}
             ]

      assert b["view"] == %{
               "mono" => %{"font" => "DejaVu Sans Mono"},
               "logview" => %{"lines" => 12},
               "steps" => ["reset-1", "update-os"]
             }

      assert json("/api/bootlog?after=1")["lines"] |> Enum.map(& &1["n"]) == [2]
      b = json("/api/bootlog?after=999999")
      refute Map.has_key?(b, "view")
      assert b["lines"] == []
      assert json("/api/bootlog?after=x")["view"]
      assert get("/api/bootlog", host: "evil.example:4041").status == 403
    end

    test "/api/sysinfo: the values with Python's types" do
      Box.put("/proc/uptime", "1234.56 999.0\n")
      Box.put("/proc/meminfo", "MemTotal:        3884000 kB\nMemFree: 1 kB\nMemAvailable:    2000000 kB\n")
      Box.put("/sys/class/thermal/thermal_zone0/temp", "45250\n")
      Box.put("/proc/device-tree/model", "Raspberry Pi 4 Model B Rev 1.5\0")
      Box.put("/proc/device-tree/serial-number", "10000000abcdef12\0")
      Box.put("/proc/sys/kernel/osrelease", "6.1.10-rpi\n")
      Box.put("/etc/os-release", "NAME=Photon\nPRETTY_NAME=\"VMware Photon OS/Linux\"\n")
      Box.put("/etc/alnasl/image-version", "7.2\n")
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=\"v7\"\nALNASL_VERSION=\"7.2.1\"\n")
      Box.put("/proc/cmdline", "console=serial0 alnasl.slot=B quiet\n")
      Box.put("/opt/alnasl/current/VERSION", "1.4.0\n")
      Box.put("/run/alnasl-kiosk/state", "path=cage mode=1920x1080\n")
      Box.put("/sys/class/net/eth0/carrier", "1\n")

      runner(fn
        ["ip", "-j", "-4", "addr", "show", "eth0"] ->
          {0, ~s([{"addr_info": [{"local": "192.168.1.9", "prefixlen": 24}, {"local": "10.42.0.1", "prefixlen": 24}]}])}

        _ ->
          nil
      end)

      s = json("/api/sysinfo")

      assert s == %{
               "hostname" => hostname(),
               "model" => "Raspberry Pi 4 Model B Rev 1.5",
               "serial" => "cdef12",
               "kernel" => "6.1.10-rpi",
               "os" => "VMware Photon OS/Linux",
               "image" => "7.2",
               "image_release" => %{"train" => "v7", "version" => "7.2.1", "slot" => "B"},
               "alnasl" => "1.4.0",
               "uptime" => 1234,
               "mem_total" => 3_884_000 * 1024,
               "mem_avail" => 2_000_000 * 1024,
               "disk_total" => 4096 * 1_000_000,
               "disk_free" => 4096 * 500_000,
               "temp_c" => 45.2,
               "display" => "path=cage mode=1920x1080",
               "net" => %{"eth0" => ["192.168.1.9/24"]}
             }

      assert ran?(["stat", "-f", "-c", "%S %b %a", "/"])
    end

    test "/api/sysinfo on an empty box" do
      runner(fn
        ["stat" | _] -> {1, ""}
        _ -> nil
      end)

      s = json("/api/sysinfo")
      assert s["temp_c"] == nil and s["os"] == "?" and s["image"] == "?" and s["alnasl"] == "?"
      assert s["uptime"] == 0 and s["display"] == "unknown" and s["net"] == %{}
      assert s["image_release"] == %{"train" => "", "version" => "", "slot" => ""}
    end

    test "round(x, 1) as Python does it" do
      alias AlnaslSetup.Server.Py
      assert Py.round(45.25, 1) == 45.2
      assert Py.round(45.35, 1) == 45.4
      assert Py.round(45.15, 1) == 45.1
      assert Py.round(0.05, 1) == 0.1
      assert Py.round(2.675, 2) == 2.67
      assert Py.round(-1.25, 1) == -1.2
      assert Py.round(3.0, 1) == 3.0
      assert Py.round(12.0, 1) |> is_float()
    end
  end

  # -------------------------------------------------------------------------------- diagnostics --

  describe "diagnostics" do
    test "/api/diag and /api/diag/journals shapes" do
      d = json("/api/diag")
      assert length(d["checks"]) == 6 and is_binary(d["verdict"])
      assert Enum.map(d["sections"], & &1["id"]) == ~w(wifi network role services kiosk updates)
      assert d["sections"] |> Enum.find(&(&1["id"] == "kiosk")) |> Map.get("text") =~ "browser heartbeat: never"
      j = json("/api/diag/journals")
      assert length(j["journals"]) == 25
    end

    test "/api/diag/save writes the report to the boot partition" do
      Box.put("/proc/mounts", "/dev/mmcblk0p1 /boot/efi vfat rw 0 0\n")
      File.mkdir_p!(Sys.path("/boot/efi"))
      r = ok!(post("/api/diag/save", %{}))
      assert r["ok"] == true and r["file"] =~ ~r/^alnasl-diagnostics-\d{8}-\d{6}\.txt$/
      assert r["where"] == "the boot partition of the SD card (the small drive that shows up on a PC)"
      text = Sys.read("/boot/efi/" <> r["file"])
      assert text =~ "ALNASL HALL BOX DIAGNOSTICS\r\n"
      assert text =~ "role:        none this boot (chosen: default)\r\n"
    end

    test "/api/diag/save when the boot partition cannot be had" do
      r = post("/api/diag/save", %{})
      assert r.status == 400

      assert r.json == %{
               "error" =>
                 "Could not write to the SD card: The boot partition (/boot/efi) is not mounted and could not be mounted."
             }
    end
  end
end
