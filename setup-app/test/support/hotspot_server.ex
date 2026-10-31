defmodule AlnaslSetup.Test.HotspotServer do
  @moduledoc """
  Stands in for the setup server's functions the hotspot daemon calls in-process (`AlnaslSetup.Wifi`,
  `AlnaslSetup.Server`). Install with `HotspotServer.install(%{...})`; what it answers comes from that map,
  and the calls that change something are sent to the process that made them (the test, when it drives
  `AlnaslSetup.Hotspot.iterate/1` itself):

      {:connect, ssid, passphrase, hidden, country}
      {:write_wpa, country, nets}
      {:scan}
      {:arkab_join_pending}
  """
  import ExUnit.Callbacks

  def install(stub \\ %{}) do
    Application.put_env(:alnasl_setup, :hotspot_server, __MODULE__)
    Application.put_env(:alnasl_setup, :hotspot_stub, stub)
    Application.put_env(:alnasl_setup, :hotspot_sleep, fn _ms -> :ok end)

    on_exit(fn ->
      for k <- [:hotspot_server, :hotspot_stub, :hotspot_sleep], do: Application.delete_env(:alnasl_setup, k)
    end)
  end

  defp stub(key, default), do: Map.get(Application.get_env(:alnasl_setup, :hotspot_stub, %{}), key, default)

  def scan do
    send(self(), {:scan})
    stub(:scan, %{"networks" => []})
  end

  def connect(ssid, passphrase, hidden, country) do
    send(self(), {:connect, ssid, passphrase, hidden, country})

    case stub(:connect, %{"ok" => true, "ip" => "192.168.1.9"}) do
      f when is_function(f, 4) -> f.(ssid, passphrase, hidden, country)
      r -> r
    end
  end

  def parse_wpa, do: {stub(:country, "BE"), stub(:nets, [])}

  def write_wpa(country, nets) do
    send(self(), {:write_wpa, country, nets})
    :ok
  end

  def wlan_ip, do: stub(:wlan_ip, nil)
  def wpa_conf, do: "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
  def arkab_pending_file, do: "/run/alnasl-setup/arkab-pending.json"

  def arkab_join_pending do
    send(self(), {:arkab_join_pending})
    stub(:arkab_result, nil)
  end
end
