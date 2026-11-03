defmodule AlnaslSetup.Compact do
  @moduledoc """
  The compact screen (v7.4, docs/spi-screens.md): what a 480x320 or 320x240 panel shows instead of the menu and
  the role's own page. It has to work with nobody touching it, so it is two pictures that change by themselves:

  - a QR code: the setup hotspot's Wi-Fi while that is up (a phone that joins gets the setup page by itself),
    else the role's own page on the hall network (http://<address>:<port>/). Always, while the box is not set
    up; and for the first two minutes after every start, so whoever just plugged it in can get in.
  - the box's status: network and addresses, the role's app up or down, version, role.

  A working stylus adds a menu (the page in app.js); nothing here depends on it.
  `decide/1` is the pure part (compact_test.exs); `status/1` feeds it from the box.
  """
  alias AlnaslSetup.{QR, SmallScreen, Sys}
  alias AlnaslSetup.Server.{Box, Net, PortalApi, State}

  @qr_seconds 120

  def qr_seconds, do: @qr_seconds

  @doc """
  Which picture, from `%{done, since, now, force_qr, hotspot, addrs, port}`: `since` is when this boot's
  first compact page was shown (seconds, like `now`), `hotspot` is /api/hotspot's answer, `addrs` the box's
  addresses (`%{"iface", "ip"}`), `port` the role's page (nil: the role has none).
  """
  def decide(i) do
    left = max(0, ceil(i.since + @qr_seconds - i.now))

    view =
      cond do
        not i.done -> "qr"
        i.force_qr -> "qr"
        left > 0 -> "qr"
        true -> "stats"
      end

    %{"view" => view, "qr_left" => if(i.done and not i.force_qr, do: left, else: 0), "qr" => qr_target(i)}
  end

  @doc "What the QR code says: the hotspot first (it reaches the setup), then the role's page, else nothing."
  def qr_target(i) do
    hs = i.hotspot || %{}
    ssid = hs["ssid"]
    pw = hs["password"]

    cond do
      hs["active"] == true and is_binary(ssid) and ssid != "" and is_binary(pw) and pw != "" ->
        %{"kind" => "hotspot", "text" => QR.wifi_payload(ssid, pw), "ssid" => ssid, "password" => pw}

      i.port != nil and i.addrs != [] ->
        a = Enum.find(i.addrs, &(&1["iface"] == "eth0")) || hd(i.addrs)
        url = "http://#{a["ip"]}:#{i.port}/"
        %{"kind" => "url", "text" => url, "url" => url}

      true ->
        %{"kind" => "none"}
    end
  end

  @doc "The QR symbol as rows of \"0\"/\"1\" (the page draws it on a canvas; the menu pages carry no images)."
  def rows(text) do
    case State.get(:compact_qr) do
      {^text, r} ->
        r

      _ ->
        r = text |> QR.encode() |> Enum.map(fn row -> Enum.map_join(row, &if(&1, do: "1", else: "0")) end)
        State.put(:compact_qr, {text, r})
        r
    end
  end

  @doc "GET /api/compact: the picture to show and everything on it."
  def status(force_qr \\ false) do
    now = Sys.now()

    since =
      case State.get(:compact_since) do
        nil ->
          State.put(:compact_since, now)
          now

        t ->
          t
      end

    role = Box.running_role()
    port = Box.role_port()[role]
    addrs = Net.box_addresses()
    hotspot = PortalApi.hotspot_screen()
    done = Box.setup_done?()
    d = decide(%{done: done, since: since, now: now, force_qr: force_qr, hotspot: hotspot, addrs: addrs, port: port})
    qr = d["qr"]
    touch = SmallScreen.touch_status()

    Map.merge(d, %{
      "qr" => Map.drop(qr, ["text"]),
      "rows" => if(qr["kind"] == "none", do: [], else: rows(qr["text"])),
      "done" => done,
      "role" => role,
      "role_up" => port != nil and Box.role_up?(role),
      "role_port" => port,
      "addrs" => addrs,
      "hostname" => Box.hostname(),
      "version" => Box.image_release()["version"],
      "hotspot" => %{"active" => hotspot["active"] == true, "ssid" => hotspot["ssid"]},
      "touch" => touch["touch"] != "off" and touch["status"] == "ready",
      "debug_ssh" => Sys.exists?("/etc/alnasl/debug-ssh")
    })
  end
end
