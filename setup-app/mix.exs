defmodule AlnaslSetup.MixProject do
  use Mix.Project

  # The box's own programs, in one release (they used to be Python):
  #   the setup server (127.0.0.1:4041), the setup hotspot daemon, the captive portal (10.42.0.1:80),
  #   the boot screen painter (alnasl-splash) and the system image updater (alnasl-system-update).
  # No dependencies: OTP and Elixir's standard library only (JSON is Elixir's own since 1.18).
  # Built for aarch64 on the build VM (setup-app/Dockerfile, scripts/build-setup.sh), installed to
  # /opt/alnasl-setup by assemble.sh.
  def project do
    [
      app: :alnasl_setup,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [],
      releases: [
        alnasl_setup: [
          include_executables_for: [:unix],
          include_erts: true,
          applications: [runtime_tools: :none],
          strip_beams: true
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets, :public_key],
      mod: {AlnaslSetup.Application, []}
    ]
  end
end
