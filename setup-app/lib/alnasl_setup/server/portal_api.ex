defmodule AlnaslSetup.Server.PortalApi do
  @moduledoc """
  The setup hotspot and its portal, as the setup server answers them (docs/captive-portal.md). The
  hotspot daemon (AlnaslSetup.Hotspot) owns wlan0 while the hotspot is on and writes what it is doing to
  /run/alnasl-hotspot/status.json; this module answers the page that phones see on the hotspot (the
  portal at 10.42.0.1:80, which passes ONLY the /api/portal calls on to here) and the box's own screen
  (/api/hotspot, loopback, which is the one place the password is shown). Nothing here erases, updates
  or re-roles the box: the portal's calls are Wi-Fi, the box's access PIN (set, never read) and Arkab's join link.
  """
  alias AlnaslSetup.{Json, Sys, Wifi}
  alias AlnaslSetup.Server.{Box, Net, Py}

  @hotspot_status "/run/alnasl-hotspot/status.json"
  @hotspot_file "/boot/efi/alnasl-hotspot.txt"
  @arkab_pending "/var/lib/alnasl-setup/arkab-join.pending"
  @arkab_result "/var/lib/alnasl-setup/arkab-join.result"
  # a join code is good for 15 minutes on the server's side
  @arkab_pending_max 900

  def arkab_pending_file, do: @arkab_pending

  def hotspot_status do
    case Json.decode_or_nil(Sys.read(@hotspot_status, "{}")) do
      %{} = s -> s
      _ -> %{}
    end
  end

  @doc "GET /api/hotspot, for the box's own screen: the hotspot's name and password while it is on."
  def hotspot_screen do
    s = hotspot_status()

    out = %{
      "active" => Wifi.hotspot_active?(),
      "ssid" => s["ssid"],
      "portal" => "http://10.42.0.1/",
      "reason" => s["reason"],
      "starts_at" => s["starts_at"]
    }

    if out["active"] do
      hs = Py.mod(:hotspot)
      parsed = hs.parse_file(Sys.read(@hotspot_file))
      pw = Map.get(parsed, "password") || Map.get(parsed, :password) || ""
      Map.put(out, "password", if(hs.valid_password?(pw), do: pw, else: nil))
    else
      out
    end
  end

  @doc "Where the box can be reached once it is on the hall's network: its name, and its page if it has one."
  def where_next(role \\ nil) do
    role = role || Box.running_role()
    host = Box.hostname()
    port = Map.get(%{"alnasl" => 4040, "arkab" => Box.role_port()["arkab"]}, role)

    %{
      "host" => host,
      "mdns" => host <> ".local",
      "port" => port,
      "url" => if(port, do: "http://#{host}.local:#{port}/", else: nil)
    }
  end

  @doc "GET /api/portal: everything the setup page on the hotspot shows. No secrets."
  def portal_info do
    role = Box.running_role()
    s = hotspot_status()

    out = %{
      "role" => role,
      "hostname" => Box.hostname(),
      "addresses" => Net.box_addresses(),
      "next" => where_next(role),
      "hotspot" => %{"active" => Wifi.hotspot_active?(), "ssid" => s["ssid"], "reason" => s["reason"]},
      "last_join" => s["last_join"],
      "country" => elem(Wifi.parse_wpa(), 0),
      "lang" => Box.lang(),
      "saved" => Wifi.saved()["saved"]
    }

    if role == "arkab" do
      pend = Box.read_json(@arkab_pending)

      Map.put(out, "arkab", %{
        "up" => Box.role_up?("arkab"),
        "pending" => pend != nil and pend != %{},
        "last" => Box.read_json(@arkab_result)
      })
    else
      out
    end
  end

  def portal_join(b) do
    ssid = Py.str_or_empty(b["ssid"])
    pw = Py.str_or_empty(b["passphrase"])
    country = Wifi.validate(ssid, pw, if(Py.truthy?(b["country"]), do: Py.str(b["country"]), else: "BE"))

    if not Wifi.hotspot_active?() do
      # the portal page only exists while the hotspot is on; this is the odd race
      Wifi.connect(ssid, pw, b["hidden"], country)
    else
      Wifi.hotspot_join_request(ssid, pw, b["hidden"], country)

      %{
        "ok" => true,
        "switching" => true,
        "ssid" => ssid,
        "hotspot" => hotspot_status()["ssid"],
        "next" => where_next()
      }
    end
  end

  defp arkab_join_now(link) do
    {ok, reason} = Py.mod(:arkab_live).join(link)
    Box.write_json_private(@arkab_result, %{"ok" => ok, "reason" => reason, "at" => Sys.now()})
    Py.log("Arkab join from the setup page: #{reason}")
    {ok, reason}
  end

  @doc """
  Arkab's join link. With a network now (Ethernet beside the hotspot), Arkab is asked at once over
  loopback; without one (the usual case: the box is on the hotspot because it has no network), the link
  waits here and the hotspot daemon hands it over as soon as the Wi-Fi works.
  """
  def portal_arkab_join(b) do
    if Box.running_role() != "arkab", do: raise(ArgumentError, "not_arkab")
    link = Py.mod(:arkab_live).valid_link(Py.str_or_empty(b["link"]))
    if not Py.truthy?(link), do: raise(ArgumentError, "not_a_link")

    if Net.box_addresses() != [] and Box.role_up?("arkab") do
      {ok, reason} = arkab_join_now(link)
      %{"ok" => ok, "reason" => reason, "pending" => false}
    else
      Box.write_json_private(@arkab_pending, %{"link" => link, "t" => Sys.now()})
      File.rm(Sys.path(@arkab_result))
      %{"ok" => true, "pending" => true}
    end
  end

  @doc "Called by the hotspot daemon once the box has a network: the waiting join link, if any."
  def arkab_join_pending do
    pend = Box.read_json(@arkab_pending)

    cond do
      pend == nil or pend == %{} ->
        nil

      Sys.now() - (Py.float(Map.get(pend, "t", 0)) || 0.0) > @arkab_pending_max ->
        File.rm!(Sys.path(@arkab_pending))
        Box.write_json_private(@arkab_result, %{"ok" => false, "reason" => "expired", "at" => Sys.now()})
        "expired"

      Box.running_role() != "arkab" or Net.box_addresses() == [] or not Box.role_up?("arkab") ->
        nil

      true ->
        File.rm!(Sys.path(@arkab_pending))
        arkab_join_now(Py.str_or_empty(pend["link"])) |> elem(1)
    end
  end
end
