defmodule AlnaslSetup.Server.Net do
  @moduledoc """
  The wired and wireless network settings (was the network part of server.py): what each interface has,
  a static address as a systemd-networkd drop-in, and confirm-or-revert: a change nobody confirms within
  the window is undone by itself, so a setting that cuts the box off undoes itself.

  The pending changes live in `AlnaslSetup.Server.State`; each carries a token, and a timer only reverts
  the change it was started for.
  """
  alias AlnaslSetup.{Json, Lock, Sys, Wifi}
  alias AlnaslSetup.Server.{Box, Py, State}

  @netd "/etc/systemd/network"
  @dropin %{
    "eth0" => @netd <> "/10-wired.network.d/50-alnasl.conf",
    "wlan0" => @netd <> "/20-wireless.network.d/50-alnasl.conf"
  }
  # 10.42.0.0/24, the setup hotspot's own network
  @hotspot_net 10 * 16_777_216 + 42 * 65_536

  def ifaces, do: Map.keys(@dropin)

  defp confirm_seconds, do: Py.env(:net_confirm_seconds, 60)

  def ipv4_info(iface) do
    {_rc, out} = Sys.run(["ip", "-j", "-4", "addr", "show", iface])

    try do
      [first | _] = Json.decode_or_nil(out)
      Enum.map(first["addr_info"], fn a -> a["local"] <> "/" <> Py.str(a["prefixlen"]) end)
    rescue
      _ -> []
    end
  end

  def read_dropin(iface) do
    case Sys.read(@dropin[iface]) do
      "" ->
        %{"mode" => "dhcp"}

      text ->
        text
        |> String.split("\n")
        |> Enum.reduce(%{"mode" => "static", "dns" => []}, fn
          "Address=" <> v, d -> Map.put(d, "address", v)
          "Gateway=" <> v, d -> Map.put(d, "gateway", v)
          "DNS=" <> v, d -> Map.update!(d, "dns", &(&1 ++ String.split(v)))
          _, d -> d
        end)
    end
  end

  defp default_gateway(iface) do
    {_rc, out} = Sys.run(["ip", "-j", "route", "show", "default", "dev", iface])

    case Json.decode_or_nil(out) do
      [%{} = r | _] -> r["gateway"]
      _ -> nil
    end
  end

  defp wpa_kv(args) do
    {_rc, out} = Sys.run(["wpa_cli", "-p", "/run/wpa_supplicant", "-i", "wlan0" | args], timeout: 10)
    AlnaslSetup.Diag.kv(out)
  end

  def net_status do
    res =
      for iface <- ~w(eth0 wlan0), into: %{} do
        present = Sys.exists?("/sys/class/net/" <> iface)

        {iface,
         %{
           "present" => present,
           "link" => present and String.trim(Sys.read("/sys/class/net/#{iface}/carrier")) == "1",
           "addresses" => if(present, do: ipv4_info(iface), else: []),
           "gateway" => if(present, do: default_gateway(iface), else: nil),
           "config" => read_dropin(iface),
           "mac" => String.trim(Sys.read("/sys/class/net/#{iface}/address"))
         }}
      end

    st = if res["wlan0"]["present"], do: wpa_kv(["status"]), else: %{}

    res =
      if st["wpa_state"] == "COMPLETED" do
        sig = wpa_kv(["signal_poll"])

        update_in(
          res["wlan0"],
          &Map.merge(&1, %{"ssid" => Wifi.wpa_unescape(Map.get(st, "ssid", "")), "rssi" => sig["RSSI"]})
        )
      else
        res
      end

    res =
      if res["wlan0"]["present"] and Wifi.hotspot_active?() do
        # wlan0 is the box's own setup hotspot, not a way onto the hall's network: say that, and keep
        # 10.42.0.1 out of the box's addresses, where it looked like a connection and fooled a human.
        update_in(
          res["wlan0"],
          &Map.merge(&1, %{
            "hotspot" => AlnaslSetup.Server.PortalApi.hotspot_status()["ssid"] || "Alnasl-setup",
            "addresses" => hall_side(&1["addresses"]),
            "gateway" => nil
          })
        )
      else
        res
      end

    {_rc, out} = Sys.run(["resolvectl", "dns"])
    dns = Regex.scan(~r/\b\d+\.\d+\.\d+\.\d+\b/, out) |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()
    Map.merge(res, %{"dns" => dns, "hostname" => Box.hostname()})
  end

  defp hotspot_ip?(ip), do: Py.in_net?(ip, @hotspot_net, 24)

  @doc "The addresses (a.b.c.d/n) that are not the setup hotspot's own."
  def hall_side(addresses) do
    Enum.filter(addresses, fn a ->
      try do
        case Py.ip_interface(a) do
          {4, ip, _} -> not hotspot_ip?(ip)
          {6, _, _} -> true
        end
      rescue
        ArgumentError -> false
      end
    end)
  end

  @doc "The box's IPv4 addresses on the hall's side (never the hotspot's own)."
  def box_addresses do
    for iface <- ~w(eth0 wlan0),
        a <- ipv4_info(iface),
        ip = a |> String.split("/") |> hd(),
        n = Py.ipv4(ip),
        n != nil and not hotspot_ip?(n),
        do: %{"iface" => iface, "ip" => ip}
  end

  # (cfg.get(k) or "").strip(); something other than text is Python's AttributeError, an internal error
  defp text_field(cfg, k) do
    case cfg[k] do
      v when is_binary(v) -> String.trim(v)
      v -> if Py.truthy?(v), do: raise("#{k}: not text"), else: ""
    end
  end

  @doc "Python's ipaddress rules: `{address/prefix, gateway, [dns]}`; raises ArgumentError with the page's text."
  def validate_static(cfg) do
    {ver, ip, len} = Py.ip_interface(Map.get(cfg, "address", ""))

    if ver != 4 or len in [0, 32],
      do: raise(ArgumentError, "Enter an IPv4 address with a prefix, such as 192.168.1.50/24.")

    gw = text_field(cfg, "gateway")

    if gw != "" do
      case Py.ip_address(gw) do
        {4, g} ->
          if not Py.in_net?(g, ip, len),
            do: raise(ArgumentError, "The gateway must be an address inside the same network.")

        _ ->
          raise ArgumentError, "The gateway must be an address inside the same network."
      end
    end

    dns =
      case cfg["dns"] do
        v when is_binary(v) -> v
        v -> if Py.truthy?(v), do: raise("dns: not text"), else: ""
      end
      |> String.split(~r/[,\s]+/u)
      |> Enum.reject(&(&1 == ""))

    for d <- dns do
      if elem(Py.ip_address(d), 0) != 4, do: raise(ArgumentError, "DNS servers must be IPv4 addresses.")
    end

    {Py.ipv4_string(ip) <> "/" <> Integer.to_string(len), gw, dns}
  end

  defp put_dropin(path, nil), do: File.rm(Sys.path(path))
  defp put_dropin(path, text), do: Sys.write_atomic(path, text)

  defp reload(iface) do
    Sys.run(["networkctl", "reload"])
    Sys.run(["networkctl", "reconfigure", iface])
  end

  def apply(iface, cfg) do
    path = Map.fetch!(@dropin, iface)
    prev = if Sys.exists?(path), do: Sys.read(path), else: nil

    text =
      if cfg["mode"] == "dhcp" do
        nil
      else
        {addr, gw, dns} = validate_static(cfg)

        "[Network]\nDHCP=no\nAddress=#{addr}\n" <>
          if(gw != "", do: "Gateway=#{gw}\n", else: "") <> Enum.map_join(dns, &"DNS=#{&1}\n")
      end

    put_dropin(path, text)
    reload(iface)

    # Confirm-or-revert: if nobody confirms in 60 s, the old setting comes back.
    pending = State.get(:pending, %{})

    case pending[iface] do
      {timer, _token, _prev} -> State.cancel(timer)
      nil -> :ok
    end

    token = make_ref()
    timer = State.timer(confirm_seconds(), fn -> revert(iface, token) end)
    State.put(:pending, Map.put(State.get(:pending, %{}), iface, {timer, token, prev}))
    %{"ok" => true, "confirm_seconds" => confirm_seconds()}
  end

  @doc "The timer's end: puts the previous file back, unless this change was confirmed or replaced since."
  def revert(iface, token) do
    Lock.with_lock(fn ->
      pending = State.get(:pending, %{})

      case pending[iface] do
        {_timer, ^token, prev} ->
          State.put(:pending, Map.delete(pending, iface))
          put_dropin(@dropin[iface], prev)
          reload(iface)
          Py.log("network settings for #{iface} were not confirmed; reverted")

        _ ->
          :ok
      end
    end)
  end

  def confirm(iface) do
    pending = State.get(:pending, %{})

    case Map.pop(pending, iface) do
      {{timer, _token, _prev}, rest} ->
        State.cancel(timer)
        State.put(:pending, rest)

      _ ->
        :ok
    end

    %{"ok" => true}
  end

  def set_hostname(name) do
    name =
      case name do
        n when is_binary(n) -> n |> String.trim() |> String.downcase()
        n -> if Py.truthy?(n), do: raise("hostname: not text"), else: ""
      end

    if not Regex.match?(~r/\A[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?\z/, name),
      do: raise(ArgumentError, "Use letters, digits and hyphens only (1 to 32 characters).")

    Sys.write_atomic("/etc/hostname", name <> "\n")
    Sys.run(["hostname", name])
    %{"ok" => true, "hostname" => name}
  end
end
