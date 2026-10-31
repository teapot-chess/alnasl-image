defmodule AlnaslSetup.Bootlog.Follower do
  @moduledoc """
  `journalctl -b -f` as a child process (an Erlang port owned by the calling process), read without
  blocking. `poll/2` returns the new shown lines as `{tag, colour, error?, text}`. It starts again by itself
  if journalctl ends (journald restarting), but not more often than every two seconds.

  The port sends its output to the process that called `new/2` (the first poll starts it), so one process
  must own the follower for its whole life: poll it from there, and `close/1` it from there.

      f = Follower.new(&AlnaslSetup.Bootlog.role/0)
      {lines, f} = Follower.poll(f, 1.0)
  """

  alias AlnaslSetup.Bootlog

  defstruct role_fun: nil,
            cmd: [],
            port: nil,
            buf: "",
            next_try: nil,
            # journalctl had nothing more to give once: the past is all read
            caught_up: false

  @max_buf 1_048_576

  def new(role_fun, cmd \\ Bootlog.journalctl_argv()) do
    %__MODULE__{role_fun: role_fun, cmd: cmd}
  end

  @doc """
  The lines that arrived within `timeout` seconds (0: only what is there now), and the follower. With
  nothing to read and a timeout, `caught_up` becomes true. When journalctl cannot be started (missing, or
  too soon after the last try) the call waits out the timeout and gives no lines, so a caller's loop does
  not spin.
  """
  def poll(%__MODULE__{} = f, timeout \\ 0.0, limit \\ 4000) do
    f = if f.port == nil, do: start(f), else: f
    ms = max(round(timeout * 1000), 0)

    if f.port == nil do
      if ms > 0, do: Process.sleep(ms)
      {[], f}
    else
      port = f.port

      receive do
        {^port, _} = msg ->
          f = f |> handle(msg) |> drain()
          {lines(f, limit), end_of_pass(f)}
      after
        ms ->
          {[], if(ms > 0, do: %{f | caught_up: true}, else: f)}
      end
    end
  end

  def close(%__MODULE__{port: nil} = f), do: f

  def close(%__MODULE__{port: port} = f) do
    kill(port)
    %{f | port: nil, buf: ""}
  end

  # ---------------------------------------------------------------- internals --
  defp now, do: System.monotonic_time(:millisecond)

  defp start(f) do
    if f.next_try != nil and now() < f.next_try do
      f
    else
      f = %{f | next_try: now() + 2000}

      try do
        [cmd | args] = f.cmd
        exe = if String.contains?(cmd, "/"), do: cmd, else: System.find_executable(cmd)

        if exe == nil or not File.exists?(exe) do
          f
        else
          # stderr and stdin to /dev/null without a shell line: sh gets the program and its arguments as argv.
          port =
            Port.open({:spawn_executable, "/bin/sh"}, [
              :binary,
              :exit_status,
              :hide,
              {:args, ["-c", "exec \"$0\" \"$@\" 2>/dev/null </dev/null", exe | args]}
            ])

          %{f | port: port, buf: ""}
        end
      rescue
        _ -> f
      end
    end
  end

  defp handle(f, {port, {:data, d}}) when port == f.port, do: %{f | buf: f.buf <> d}
  # The process ended: what is left of a half line goes with it, the next start begins clean.
  defp handle(f, {port, {:exit_status, _}}) when port == f.port, do: %{f | port: nil}
  defp handle(f, _), do: f

  # Everything that is already there, up to a megabyte of it; the rest waits for the next poll.
  defp drain(%{port: nil} = f), do: f

  defp drain(f) do
    if byte_size(f.buf) >= @max_buf do
      f
    else
      port = f.port

      receive do
        {^port, _} = msg -> f |> handle(msg) |> drain()
      after
        0 -> f
      end
    end
  end

  # Whole lines out of the buffer, parsed and filtered.
  defp lines(f, limit) do
    parts = :binary.split(f.buf, "\n", [:global])
    complete = Enum.drop(parts, -1)
    role = f.role_fun.()

    complete
    |> Enum.take(-limit)
    |> Enum.flat_map(fn raw ->
      with {:ok, e} <- JSON.decode(raw), l when l != nil <- Bootlog.entry_line(e, role) do
        [l]
      else
        _ -> []
      end
    end)
  end

  defp end_of_pass(f) do
    parts = :binary.split(f.buf, "\n", [:global])
    rest = List.last(parts)
    %{f | buf: if(f.port == nil, do: "", else: rest)}
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("sh", ["-c", "kill -9 \"$1\"", "sh", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
