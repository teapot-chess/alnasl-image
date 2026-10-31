defmodule AlnaslSetup.Sys do
  @moduledoc """
  The few things every part of the box's programs does with the system: read a file, write one
  atomically, run a command (an argument list, never a shell line), say something in the journal.

  Two seams for the tests, both in the application environment and both unset on the box:

    * `:root`   - a directory prefixed to every absolute path given to `path/1` (a fake root in a temp dir)
    * `:runner` - `fn argv, opts -> {exit_code, output} end` instead of running anything
  """

  @doc "The real location of an absolute path (under the tests' fake root when one is set)."
  def path("/" <> _ = p), do: Application.get_env(:alnasl_setup, :root, "") <> p
  def path(p), do: p

  @doc "Whole file as a binary, or `default` when it cannot be read (Python's read(path, default))."
  def read(p, default \\ "") do
    case File.read(path(p)) do
      {:ok, data} -> data
      {:error, _} -> default
    end
  end

  def exists?(p), do: File.exists?(path(p))
  def dir?(p), do: File.dir?(path(p))
  def regular?(p), do: File.regular?(path(p))

  @doc """
  Write a file so that a reader sees the old or the new one, never half of it: `<real path>.new`, then a
  rename. A symlink (v6 A/B: /etc/alnasl/keyboard.conf -> /data/...) is followed: the file it points at
  is replaced, never the link itself.
  """
  def write_atomic(p, data, mode \\ 0o644) do
    real = realpath(path(p))
    File.mkdir_p!(Path.dirname(real))
    tmp = real <> ".new"
    # The mode before the data: a 0600 file (the Wi-Fi keys) is never readable by others, not even briefly.
    File.rm(tmp)
    File.write!(tmp, "")
    File.chmod!(tmp, mode)
    File.write!(tmp, data)
    File.rename!(tmp, real)
    :ok
  end

  @doc "Like os.path.realpath: follows symlinks of every component that exists."
  def realpath(p) do
    p = Path.expand(p)
    do_realpath(Path.split(p), "/", 0)
  end

  defp do_realpath([], acc, _), do: acc
  defp do_realpath(["/" | rest], _acc, n), do: do_realpath(rest, "/", n)

  defp do_realpath([seg | rest], acc, n) when n < 40 do
    cand = Path.join(acc, seg)

    case :file.read_link_all(String.to_charlist(cand)) do
      {:ok, target} ->
        target = List.to_string(target)
        abs = if String.starts_with?(target, "/"), do: target, else: Path.expand(target, acc)
        do_realpath(Path.split(abs) ++ rest, "/", n + 1)

      {:error, _} ->
        do_realpath(rest, cand, n)
    end
  end

  defp do_realpath(segs, acc, _), do: Path.join([acc | segs])

  @doc "One line in the journal, with the program's prefix (\"alnasl-setup: ...\")."
  def log(prefix, msg) do
    IO.puts(prefix <> ": " <> to_string(msg))
  end

  @doc "Unix time as a float, like Python's time.time()."
  def now, do: :os.system_time(:microsecond) / 1_000_000

  @doc "Seconds since the box started (/proc/uptime), or `default`."
  def uptime(default \\ 0.0) do
    case Float.parse(String.trim(read("/proc/uptime", ""))) do
      {f, _} -> f
      :error -> default
    end
  end

  @doc """
  Run a command. Returns `{exit_code, output}`; never raises.

  Options:
    * `:timeout` - seconds (default 20); a command that runs longer is killed
    * `:stderr`  - `:drop` (default; Python's run(): stdout only) or `:merge` (diag.runo: both)
    * `:errors`  - `:plain` (default: {127, reason}) or `:diag` (diag.runo's "(not installed: x)" / "(timed out ...)")
  """
  def run([cmd | args] = argv, opts \\ []) do
    case Application.get_env(:alnasl_setup, :runner) do
      nil -> do_run(cmd, args, opts)
      fun when is_function(fun, 2) -> fun.(argv, opts)
    end
  end

  @doc "stdout and stderr together, with diag.runo's words for a missing command or a timeout."
  def runo(argv, timeout \\ 15), do: run(argv, timeout: timeout, stderr: :merge, errors: :diag)

  @doc "Is the command installed in one of the usual places (diag.have)?"
  def have?(cmd) do
    Enum.any?(~w(/usr/sbin /usr/bin /sbin /bin /usr/local/sbin /usr/local/bin), fn d ->
      f = path(Path.join(d, cmd))

      case File.stat(f) do
        {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _ -> false
      end
    end)
  end

  defp do_run(cmd, args, opts) do
    timeout = Keyword.get(opts, :timeout, 20)
    merge = Keyword.get(opts, :stderr, :drop) == :merge
    diag = Keyword.get(opts, :errors, :plain) == :diag

    exe = if String.contains?(cmd, "/"), do: cmd, else: System.find_executable(cmd)

    cond do
      exe == nil or not File.exists?(exe) ->
        if diag, do: {127, "(not installed: #{cmd})\n"}, else: {127, "[Errno 2] No such file or directory: '#{cmd}'"}

      true ->
        {exe, args} =
          if merge do
            {exe, args}
          else
            # stderr to /dev/null without a shell line: sh gets the program and its arguments as argv.
            {"/bin/sh", ["-c", "exec \"$0\" \"$@\" 2>/dev/null", exe | args]}
          end

        port_opts = [:binary, :exit_status, :hide, {:args, args}] ++ if(merge, do: [:stderr_to_stdout], else: [])

        try do
          port = Port.open({:spawn_executable, exe}, port_opts)
          collect(port, [], System.monotonic_time(:millisecond) + round(timeout * 1000), timeout, diag)
        rescue
          e -> {127, if(diag, do: "(#{Exception.message(e)})\n", else: Exception.message(e))}
        end
    end
  end

  defp collect(port, acc, deadline, timeout, diag) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, d}} -> collect(port, [acc | d], deadline, timeout, diag)
      {^port, {:exit_status, rc}} -> {rc, IO.iodata_to_binary(acc)}
    after
      left ->
        kill(port)

        if diag,
          do: {124, "(timed out after #{trunc(timeout)} s)\n"},
          else: {127, "Command timed out after #{timeout} seconds"}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      0 -> :ok
    end
  end
end
