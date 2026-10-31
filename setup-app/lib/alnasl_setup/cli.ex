defmodule AlnaslSetup.CLI do
  @moduledoc """
  The command-line programs, run through the release's `eval` (no application started, so nothing of the
  daemons comes up):

      /opt/alnasl-setup/bin/alnasl_setup eval 'AlnaslSetup.CLI.main()' -- <program> <args...>

  /usr/local/sbin/alnasl-splash and /usr/local/sbin/alnasl-system-update are three-line shell scripts that
  do exactly that. Programs: `splash`, `system-update`, `hotspot` (`--stop`, `--prepare`).
  The exit code is the program's.
  """

  def main(argv \\ System.argv()) do
    code =
      case argv do
        ["splash" | rest] -> AlnaslSetup.Splash.main(rest)
        ["system-update" | rest] -> AlnaslSetup.SystemUpdate.main(rest)
        ["hotspot" | rest] -> AlnaslSetup.Hotspot.main(rest)
        _ -> usage()
      end

    System.halt(if is_integer(code), do: code, else: 0)
  end

  defp usage do
    IO.puts(:stderr, "usage: alnasl_setup eval 'AlnaslSetup.CLI.main()' -- splash|system-update|hotspot [args]")
    2
  end
end
