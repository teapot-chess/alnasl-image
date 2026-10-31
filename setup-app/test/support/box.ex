defmodule AlnaslSetup.Test.Box do
  @moduledoc """
  A fake box for the tests: a temporary root directory (every `AlnaslSetup.Sys.path/1` lands in it) and
  a fake command runner that answers from a function and records what was asked.

      setup do
        Box.root!()          # a fresh fake root, removed after the test
        Box.runner!(fn ["systemctl", "is-active", _] -> {0, "active\\n"}; _ -> {0, ""} end)
        :ok
      end

  Tests that use it must be `async: false` (the seams are application environment).
  """
  import ExUnit.Callbacks

  def root! do
    root = Path.join(System.tmp_dir!(), "alnasl-setup-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:alnasl_setup, :root, root)

    on_exit(fn ->
      Application.delete_env(:alnasl_setup, :root)
      File.rm_rf!(root)
    end)

    root
  end

  @doc "Writes a file under the fake root (path given as on the box)."
  def put(path, data) do
    full = AlnaslSetup.Sys.path(path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, data)
    full
  end

  def runner!(fun) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    Application.put_env(:alnasl_setup, :runner, fn argv, _opts ->
      Agent.update(log, &[argv | &1])

      case fun.(argv) do
        {rc, out} when is_integer(rc) -> {rc, out}
        nil -> {0, ""}
      end
    end)

    on_exit(fn -> Application.delete_env(:alnasl_setup, :runner) end)
    Process.put(:box_runner_log, log)
    log
  end

  @doc "The commands run so far, oldest first."
  def ran(log \\ Process.get(:box_runner_log)), do: log |> Agent.get(& &1) |> Enum.reverse()
end
