defmodule AlnaslSetup.Application do
  @moduledoc """
  One release, three long-running programs, each its own OS process and unit:

      ALNASL_SETUP_MODE=server   alnasl-setup.service    the settings server, 127.0.0.1:4041
      ALNASL_SETUP_MODE=hotspot  alnasl-hotspot.service  the setup hotspot daemon
      ALNASL_SETUP_MODE=portal   alnasl-portal.service   the captive portal, 10.42.0.1:80

  Nothing is started when the variable is unset (the tests, and `bin/alnasl_setup eval`, which the
  command-line tools use: see `AlnaslSetup.CLI`).
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case System.get_env("ALNASL_SETUP_MODE") do
        "server" -> [AlnaslSetup.Server]
        "hotspot" -> [AlnaslSetup.Hotspot]
        "portal" -> [AlnaslSetup.Portal]
        _ -> []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: AlnaslSetup.Supervisor, max_restarts: 0)
  end
end
