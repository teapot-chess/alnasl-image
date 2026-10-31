# Stand-ins for the parts of the release that other modules provide (the boot log, the hotspot's
# file parser, Arkab's join, the system updater). The server finds them through the test-only
# `:modules` seam, so these never shadow the real modules.

defmodule AlnaslSetup.Test.FakeBootlog do
  def status(lang), do: %{"text" => "status in " <> lang}
  def role, do: "alnasl"
end

defmodule AlnaslSetup.Test.FakeFollower do
  def new(role_fun) when is_function(role_fun, 0), do: %{caught_up: false, n: 0}

  def poll(%{n: 0} = f, _timeout) do
    {[{"kernel", "kernel", false, "line one"}, {"alnasl", "app", true, "line two"}], %{f | n: 1, caught_up: true}}
  end

  def poll(f, timeout) do
    Process.sleep(round(timeout * 100))
    {[], f}
  end

  def close(_f), do: :ok
end

defmodule AlnaslSetup.Test.FakeHotspot do
  def parse_file(text) do
    pw =
      case Regex.run(~r/^password=(.*)$/m, text) do
        [_, p] -> String.trim(p)
        _ -> ""
      end

    %{"password" => pw, "hotspot" => "auto"}
  end

  def valid_password?(p), do: is_binary(p) and String.length(p) >= 8
end

defmodule AlnaslSetup.Test.FakeArkabLive do
  def valid_link("https://arkab.example/join/" <> _ = l), do: l
  def valid_link(_), do: nil
  def join(_link), do: {true, "joined"}
end

defmodule AlnaslSetup.Test.FakeSystemUpdate do
  def status do
    case Application.get_env(:alnasl_setup, :fake_sysupd) do
      nil -> raise "no status"
      s -> s
    end
  end
end
