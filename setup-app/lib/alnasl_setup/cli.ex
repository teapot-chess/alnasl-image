defmodule AlnaslSetup.CLI do
  @moduledoc """
  The command-line programs, run through the release's `eval` (no application started, so nothing of the
  daemons comes up):

      /opt/alnasl-setup/bin/alnasl_setup eval 'AlnaslSetup.CLI.main()' -- <program> <args...>

  /usr/local/sbin/alnasl-splash, alnasl-system-update and alnasl-small-screen are three-line shell scripts that
  do exactly that. Programs: `splash`, `system-update`, `hotspot` (`--stop`, `--prepare`), `small-screen` (`--status`).
  The exit code is the program's.
  """

  @doc """
  The program's arguments. The release's `eval` hands over the `--` that separates them from the expression
  (seen on the arm64 image: System.argv() is ["--", "splash", ...]), so a leading one is dropped.
  """
  def argv do
    case System.argv() do
      ["--" | rest] -> rest
      args -> args
    end
  end

  def main(argv \\ argv()) do
    code =
      case argv do
        ["splash" | rest] -> AlnaslSetup.Splash.main(rest)
        ["system-update" | rest] -> AlnaslSetup.SystemUpdate.main(rest)
        ["hotspot" | rest] -> AlnaslSetup.Hotspot.main(rest)
        ["small-screen" | rest] -> AlnaslSetup.SmallScreen.main(rest)
        _ -> usage()
      end

    System.halt(if is_integer(code), do: code, else: 0)
  end

  defp usage do
    IO.puts(
      :stderr,
      "usage: alnasl_setup eval 'AlnaslSetup.CLI.main()' -- splash|system-update|hotspot|small-screen [args]"
    )

    2
  end
end
