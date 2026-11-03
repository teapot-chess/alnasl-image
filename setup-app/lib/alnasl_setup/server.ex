defmodule AlnaslSetup.Server do
  @moduledoc """
  Alnasl hall box: settings + first-run wizard backend (was server.py).

  Runs as root, listens on 127.0.0.1:4041 ONLY (never on the LAN). Serves the single-page UI from
  /usr/local/share/alnasl-setup/www and a small JSON API. Everything it changes on the box goes through
  the modules under `AlnaslSetup.Server`; nothing from a request is ever given to a shell (argument lists
  only, input validated first).

  Every request must name this server in its Host header (a page on another site that got a browser to
  resolve its name to 127.0.0.1 does not), and every POST must carry `X-Alnasl-Setup: 1` with a JSON
  body: a page on another origin cannot send that without a CORS preflight, which this server never
  answers.

  Secrets: Wi-Fi passphrases arrive in POST bodies, are written to their root-only file (0600) and are
  never logged; the access log holds only method, path and status.
  """
  use Supervisor
  alias AlnaslSetup.{Compact, Diag, Http, Json, Lock, SmallScreen, Sys, Wifi}
  alias AlnaslSetup.Server.{Box, Help, Net, PortalApi, Printers, Py, Resolution, State}

  @port 4041
  @www "/usr/local/share/alnasl-setup/www"
  @types %{
    ".html" => "text/html; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8",
    ".svg" => "image/svg+xml",
    ".png" => "image/png"
  }
  @spa ~w(/ /setup /menu /settings /info /diag /compact /help)

  # ------------------------------------------------------------------------------------ process --

  @doc "Options: `:port` (default 4041; 0 for a free one, the tests), `:ip` (default 127.0.0.1)."
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(opts \\ []) do
    with {:ok, pid} <- Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      Py.log("listening on #{:inet.ntoa(Keyword.get(opts, :ip, {127, 0, 0, 1}))}:#{port()}")
      # a box that has just started: have the log ready before the browser asks for it
      if Sys.uptime(9999.0) < 600, do: State.bootlog_start()
      {:ok, pid}
    end
  end

  @impl true
  def init(opts) do
    dir = Sys.path(Box.state_dir())

    if not File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    children = [
      State,
      {
        Http,
        # an idle keep-alive connection must not hold a process forever
        id: __MODULE__,
        ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
        port: Keyword.get(opts, :port, @port),
        handler: &handle/1,
        server: "alnasl-setup",
        idle_timeout: 120_000,
        max_body: 20_000,
        backlog: 64,
        log: &access_log/3
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  @doc "The port the server listens on (4041 on the box)."
  def port, do: Http.port(__MODULE__)

  @doc "Called by the hotspot daemon once the box has a network: the waiting Arkab join link, if any."
  defdelegate arkab_join_pending(), to: PortalApi

  def arkab_pending_file, do: PortalApi.arkab_pending_file()

  # method, path and status only; never a body
  defp access_log(method, target, status) do
    if target != "/healthz" and not String.starts_with?(target, "/api/ping") and
         not String.contains?(target, "/api/kiosk-busy"),
       do: Py.log("#{method} #{target |> String.split("?") |> hd()} #{status}")
  end

  # --------------------------------------------------------------------------------------- HTTP --

  defp reply(code, body, ctype \\ "application/json", extra \\ [], cache \\ "no-store") do
    body = if is_map(body) or is_list(body), do: Json.encode(body), else: body
    {code, [{"Content-Type", ctype}, {"Cache-Control", cache} | extra], body}
  end

  defp closing({status, headers, body}), do: {status, headers, body, :close}

  defp obj!(%{} = b), do: b
  defp obj!(_b), do: raise("the request body is not an object")

  defp host_ok?(req) do
    p = port()
    Map.get(req.headers, "host", "") in ["127.0.0.1:#{p}", "localhost:#{p}"]
  end

  @doc false
  def handle(%{method: "GET"} = req), do: do_get(req)
  def handle(%{method: "POST"} = req), do: do_post(req)
  # BaseHTTPRequestHandler answers a method it has no do_X for with 501
  def handle(_req), do: closing(reply(501, %{"error" => "unsupported method"}))

  defp do_get(req) do
    path = req.path

    cond do
      not host_ok?(req) ->
        reply(403, %{"error" => "forbidden"})

      # first, and touching nothing that could be busy: the watchdog asks this every 10 s
      path == "/healthz" ->
        reply(200, ~s({"ok": true}))

      true ->
        try do
          get_route(path, req.query)
        rescue
          e ->
            Py.log("GET error #{path} #{inspect(e)}")
            reply(500, %{"error" => "internal error"})
        end
    end
  end

  defp get_route("/favicon.ico", _q), do: reply(204, "")

  defp get_route(path, q) do
    # the kiosk's browser is up and asking (the A/B health check waits for this)
    if path in ["/boot", "/screen", "/"], do: Box.mark_painted()

    cond do
      path == "/" ->
        start_page()

      path in ["/boot", "/screen"] ->
        # The kiosk's first page, and where it waits while Alnasl is away: the boot screen.
        reply(200, File.read!(Sys.path(@www <> "/screen.html")), @types[".html"])

      String.starts_with?(path, "/splash/") and String.ends_with?(path, ".png") ->
        f = Py.normpath(Box.splash() <> "/" <> String.replace_prefix(path, "/splash/", ""))

        if String.starts_with?(f, Box.splash() <> "/") and Sys.regular?(f),
          do: reply(200, File.read!(Sys.path(f)), @types[".png"], [], "max-age=86400"),
          else: reply(404, %{"error" => "not found"})

      String.starts_with?(path, "/api/") ->
        case api_get(path, q) do
          nil -> reply(404, %{"error" => "not found"})
          r -> reply(200, r)
        end

      true ->
        path = if path in @spa or String.starts_with?(path, "/settings/"), do: "/index.html", else: path
        f = Py.normpath(@www <> path)

        if String.starts_with?(f, @www <> "/") and Sys.regular?(f),
          do: reply(200, File.read!(Sys.path(f)), Map.get(@types, Path.extname(f), "application/octet-stream")),
          else: reply(404, %{"error" => "not found"})
    end
  end

  defp start_page do
    cond do
      # A browser that was restarted while a menu page was open goes back to that page.
      back = Box.resume_page() ->
        Py.log("start page: returning to #{back}")
        reply(302, "", "application/json", [{"Location", back}])

      # v7.4: a small screen shows the compact page, set up or not: the QR code and the status, no touch needed.
      SmallScreen.compact_ui?() ->
        reply(302, "", "application/json", [{"Location", "/compact"}])

      # Where the kiosk starts: the wizard until setup is done, then the role's own page (Alnasl, Arkab,
      # Polis or Nunki); the menu, which says what is wrong, when that is not up.
      not Box.setup_done?() ->
        reply(302, "", "application/json", [{"Location", "/setup"}])

      Box.role_wanted?() and Box.role_up?() ->
        reply(302, "", "application/json", [{"Location", "http://localhost:#{Box.role_port()[Box.running_role()]}/"}])

      true ->
        reply(302, "", "application/json", [{"Location", "/menu"}])
    end
  end

  defp do_post(req) do
    cond do
      not host_ok?(req) or Map.get(req.headers, "x-alnasl-setup") != "1" ->
        # the unread body must not be parsed as the next request
        closing(reply(403, %{"error" => "forbidden"}, "application/json", [{"Connection", "close"}]))

      req.body == :too_large ->
        reply(413, %{"error" => "too large"})

      true ->
        case Json.decode(if req.body == "", do: "{}", else: req.body) do
          {:ok, b} ->
            try do
              case Lock.with_lock(fn -> api_post(req.path, b) end) do
                nil -> reply(404, %{"error" => "not found"})
                r -> reply(200, r)
              end
            rescue
              # validation errors (Python's ValueError)
              e in ArgumentError ->
                reply(400, %{"error" => Exception.message(e)})

              e ->
                Py.log("POST error #{req.path} #{e.__struct__ |> Module.split() |> List.last()}")
                reply(500, %{"error" => "internal error"})
            end

          _ ->
            reply(400, %{"error" => "The request body is not valid JSON."})
        end
    end
  end

  # ---------------------------------------------------------------------------------------- GET --

  defp api_get(path, q) do
    case path do
      "/api/state" ->
        %{
          "done" => Box.setup_done?(),
          "lang" => Box.lang(),
          "layouts" => for({id, label, _, _, _} <- Box.layouts(), do: %{"id" => id, "label" => label}),
          "keyboard" => Box.get_keyboard(),
          "services" => Box.services_status(),
          "scale" => Box.get_kiosk_conf()["KIOSK_SCALE"],
          "alnasl_up" => Box.alnasl_up?(),
          "mode" => Box.mode_status(),
          "role_up" => Box.role_up?(),
          "role_port" => Box.role_port()[Box.running_role()],
          # v7.3: the stylus of a small screen (alnasl-screen.txt), for Settings > Touch screen
          "touch" => SmallScreen.read_state()["touch"] || "off",
          # v7.4: the kiosk's home is the compact page (Home buttons go there through /)
          "compact" => SmallScreen.compact_ui?()
        }

      "/api/resolution" ->
        Resolution.status()

      "/api/touch" ->
        SmallScreen.touch_status()

      # v7.4: the compact screen's picture (?qr=1: the QR code, asked for from its menu)
      "/api/compact" ->
        Compact.status(Map.has_key?(Py.parse_qs(q), "qr"))

      "/api/net" ->
        Net.net_status()

      "/api/wifi/scan" ->
        Wifi.scan()

      "/api/wifi/saved" ->
        Wifi.saved()

      "/api/sysinfo" ->
        Box.sysinfo()

      "/api/ping" ->
        qs = Py.parse_qs(q)
        Box.page_ping(List.first(qs["p"] || [""]), Map.has_key?(qs, "first"))
        %{"ok" => true}

      # the kiosk watchdog reads the ping file itself; this is the same answer for people
      "/api/kiosk-busy" ->
        Box.kiosk_busy()

      "/api/diag" ->
        Box.diag_info()

      "/api/diag/journals" ->
        %{"journals" => Diag.journals()}

      # the "Test Wi-Fi scan" button: raw outputs, nothing hidden
      "/api/diag/scan" ->
        Map.put(Wifi.scan(), "raw", Wifi.last_scan())

      "/api/help" ->
        Help.status()

      "/api/bootscreen" ->
        Box.mark_painted()
        Box.bootscreen()

      # ?after=N: the log lines after N, the status line (v7)
      "/api/bootlog" ->
        Box.bootlog_get(q)

      "/api/system" ->
        Box.system_status()

      "/api/mode" ->
        Box.mode_status()

      "/api/printers" ->
        Printers.status()

      "/api/printers/usb" ->
        Printers.usb()

      "/api/sound" ->
        Box.sound_status()

      # the box's own screen only: the portal never passes this one on
      "/api/hotspot" ->
        PortalApi.hotspot_screen()

      "/api/portal" ->
        PortalApi.portal_info()

      "/api/portal/scan" ->
        Wifi.scan()

      _ ->
        nil
    end
  end

  # --------------------------------------------------------------------------------------- POST --

  # b.get(k, default): a body that is JSON but not an object fails where it is read, as in Python
  defp g(b, k, default \\ nil)
  defp g(%{} = b, k, default), do: Map.get(b, k, default)
  defp g(_b, _k, _default), do: raise("the request body is not an object")

  defp api_post(path, b) do
    case path do
      "/api/lang" ->
        if g(b, "lang") in ["en", "nl"], do: Box.set_state(lang: b["lang"])
        %{"ok" => true}

      "/api/keyboard" ->
        r = Box.set_keyboard(g(b, "layout", ""))
        if Py.truthy?(g(b, "restart_kiosk")), do: Box.restart_kiosk()
        r

      "/api/wifi/connect" ->
        Wifi.connect(g(b, "ssid", ""), g(b, "passphrase", ""), g(b, "hidden"), g(b, "country", "BE"))

      "/api/wifi/forget" ->
        Wifi.forget(g(b, "ssid", ""))

      "/api/wifi/country" ->
        Wifi.set_country(g(b, "country", ""))

      "/api/net/set" ->
        if g(b, "iface") not in Net.ifaces(), do: raise(ArgumentError, "bad interface")
        Net.apply(b["iface"], b)

      "/api/net/confirm" ->
        Net.confirm(g(b, "iface", ""))

      "/api/hostname" ->
        Net.set_hostname(g(b, "hostname", ""))

      "/api/services" ->
        Box.set_services(obj!(b))

      "/api/scale" ->
        r = Box.set_scale(g(b, "scale", 100))
        Box.restart_kiosk()
        r

      "/api/resolution" ->
        Resolution.set(Py.str(g(b, "mode", "auto")))

      "/api/resolution/confirm" ->
        Resolution.confirm()

      "/api/resolution/undo" ->
        Resolution.cancel()

      # v7.3, Settings > Touch screen: {"samples": [[cross x, cross y, tap x, tap y] x4]}, fractions of the screen.
      # The new matrix is in the udev database at once; X reads it when it starts, so the screen restarts.
      "/api/touch/calibrate" ->
        {_c, res} = SmallScreen.save_calibration(g(b, "samples"))
        Box.restart_kiosk()
        %{"ok" => true, "error_pct" => Float.round(res * 100, 1)}

      "/api/touch/reset" ->
        SmallScreen.reset_calibration()
        Box.restart_kiosk()
        %{"ok" => true}

      "/api/finish" ->
        finish(b)

      "/api/diag/save" ->
        Box.diag_save()

      # blocks up to 25 s; the answer is the code or the reason
      "/api/help/send" ->
        Help.send_report()

      # "" puts the default back
      "/api/help/url" ->
        Help.set_url(Py.str(g(b, "url", "")))

      "/api/console/show" ->
        Box.console_show()

      "/api/screen/stop" ->
        Box.screen_stop()

      # alnasl-setup
      "/api/reopen" ->
        File.rm(Sys.path(Box.done_file()))
        %{"ok" => true}

      "/api/power" ->
        Box.power(g(b, "action", ""))

      "/api/reset" ->
        Box.factory_reset(g(b, "confirm", ""))

      # {"mode": "alnasl"|"arkab"|"polis"|"nunki" (or v6's "master"|"slave"), "confirm": "SWITCH"};
      # Settings and Arkab's page
      "/api/mode" ->
        Box.switch_mode(Py.str(g(b, "mode", "")), g(b, "confirm", ""))

      # Settings > Printers (polis) and Settings > Sound (nunki)
      "/api/printers/" <> what when what in ["add", "default", "remove", "test"] ->
        if Box.running_role() != "polis", do: raise(ArgumentError, "not_polis")
        apply(Printers, String.to_existing_atom(what), [obj!(b)])

      p when p in ["/api/sound", "/api/sound/test"] ->
        if Box.running_role() != "nunki", do: raise(ArgumentError, "not_nunki")
        if p == "/api/sound", do: Box.set_sound(obj!(b)), else: Box.sound_test()

      # System updates (menu > Settings > System updates; Arkab's status page through the same API).
      "/api/system/check" ->
        Box.system_check()

      # a newer image of this box's own train, now (round check included)
      "/api/system/install" ->
        if g(b, "confirm") != "INSTALL", do: raise(ArgumentError, "Not confirmed.")
        Box.system_request("install", nil, g(b, "by", "menu"))

      # the next train: only ever this way, never by itself
      "/api/system/upgrade" ->
        if g(b, "confirm") != "UPGRADE", do: raise(ArgumentError, "Not confirmed.")
        Box.system_request("upgrade", Py.str(g(b, "train", "")), g(b, "by", "menu"))

      # "" puts the default back
      "/api/system/url" ->
        Box.system_url(Py.str(g(b, "url", "")))

      # The setup page on the hotspot (the portal passes these three on, and nothing else that changes anything).
      "/api/portal/join" ->
        PortalApi.portal_join(obj!(b))

      # v7.4: the compact screen's number pad; the same rules and the same hand-over as the setup page's
      "/api/compact/arkab-pin" ->
        PortalApi.portal_arkab_pin(obj!(b))

      "/api/portal/arkab-pin" ->
        PortalApi.portal_arkab_pin(obj!(b))

      "/api/portal/arkab-join" ->
        PortalApi.portal_arkab_join(obj!(b))

      _ ->
        nil
    end
  end

  # The wizard's first question (what is this box) is only written here, at the end: a box that lost
  # power half way through the wizard must not come back as something it cannot finish the wizard on.
  defp finish(b) do
    want =
      case g(b, "mode") do
        nil -> nil
        w -> Box.set_mode(Py.str(w))
      end

    Sys.write_atomic(Box.done_file(), "1\n")
    Box.page_ping("")

    if want != nil and want != Box.running_role() do
      # the other app takes the box over at the next boot
      Box.power("reboot")
      %{"ok" => true, "reboot" => true}
    else
      Box.restart_kiosk()
      %{"ok" => true}
    end
  end
end
