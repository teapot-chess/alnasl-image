defmodule AlnaslSetup.Server.State do
  @moduledoc """
  What the Python server kept in module globals, owned by one process under the server's supervisor:
  the last page ping (LAST_PAGE), the raw text of the last Wi-Fi scan test (LAST_SCAN), the network
  settings waiting for a confirmation (PENDING), the resolution waiting for one (RES_PENDING), and the
  boot log buffer with its reader (BOOTLOG).

  Timers (Python's threading.Timer) are `Process.send_after/3` to this process; when one fires, its
  action runs in a process of its own, so a slow action never holds this one up. They die with it.

  When this process is not running (the hotspot daemon calls the Wi-Fi functions in another program),
  reads give the default and writes do nothing, like a fresh Python module would.
  """
  use GenServer
  alias AlnaslSetup.Server.Py

  @bootlog_idle 120
  @bootlog_max 400

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def child_spec(arg), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}}

  defp running?, do: Process.whereis(__MODULE__) != nil

  @doc "A value (`default` when unset or when the server is not running)."
  def get(key, default \\ nil) do
    if running?(), do: GenServer.call(__MODULE__, {:get, key, default}), else: default
  end

  def put(key, value) do
    if running?(), do: GenServer.call(__MODULE__, {:put, key, value}), else: :ok
  end

  @doc "Takes a value out (Python's dict.pop(key, None))."
  def pop(key) do
    if running?(), do: GenServer.call(__MODULE__, {:pop, key}), else: nil
  end

  @doc "Runs `fun` after `seconds`, in its own process. Returns a timer reference (nil if not running)."
  def timer(seconds, fun) do
    if running?(), do: GenServer.call(__MODULE__, {:timer, seconds, fun}), else: nil
  end

  def cancel(nil), do: :ok
  def cancel(ref), do: Process.cancel_timer(ref) && :ok

  # ------------------------------------------------------------------------------- boot log ----
  # v7: the boot log for the browser's /boot page (screen.html), after X has taken the screen from the
  # framebuffer painter. The reader follows journalctl -b -f (AlnaslSetup.Bootlog.Follower); it starts
  # with the server when the box has just booted (so it has caught up by the time Chromium asks) and
  # otherwise on the first request, and stops after two minutes without one.

  def bootlog_start do
    if running?(), do: GenServer.call(__MODULE__, :bootlog_start), else: :ok
  end

  @doc "`%{seq, ready, lines: [{n, tag, colour, err, text}]}` with the lines after `after` (the last 60)."
  def bootlog_snapshot(after_n) do
    if running?(),
      do: GenServer.call(__MODULE__, {:bootlog_snapshot, after_n}),
      else: %{seq: 0, ready: false, lines: []}
  end

  # --------------------------------------------------------------------------------- server ----

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{kv: %{}, bl: %{lines: :queue.new(), count: 0, seq: 0, reader: nil, asked: 0.0, ready: false}}}
  end

  @impl true
  def handle_call({:get, k, d}, _from, s), do: {:reply, Map.get(s.kv, k, d), s}
  def handle_call({:put, k, v}, _from, s), do: {:reply, :ok, %{s | kv: Map.put(s.kv, k, v)}}
  def handle_call({:pop, k}, _from, s), do: {:reply, Map.get(s.kv, k), %{s | kv: Map.delete(s.kv, k)}}

  def handle_call({:timer, seconds, fun}, _from, s) do
    {:reply, Process.send_after(self(), {:fire, fun}, max(round(seconds * 1000), 0)), s}
  end

  def handle_call(:bootlog_start, _from, s) do
    bl = %{s.bl | asked: Py.monotonic()}

    bl =
      if bl.reader == nil do
        me = self()
        %{bl | reader: spawn_link(fn -> reader(me) end)}
      else
        bl
      end

    {:reply, :ok, %{s | bl: bl}}
  end

  def handle_call(:bootlog_asked, _from, s), do: {:reply, s.bl.asked, s}

  def handle_call({:bootlog_snapshot, after_n}, _from, s) do
    lines = s.bl.lines |> :queue.to_list() |> Enum.filter(&(elem(&1, 0) > after_n)) |> Enum.take(-60)
    {:reply, %{seq: s.bl.seq, ready: s.bl.ready, lines: lines}, s}
  end

  @impl true
  def handle_cast({:bootlog_lines, new, caught_up}, s) do
    bl =
      Enum.reduce(new, s.bl, fn line, bl ->
        seq = bl.seq + 1
        q = :queue.in(List.to_tuple([seq | Tuple.to_list(line)]), bl.lines)
        {q, count} = if bl.count + 1 > @bootlog_max, do: {:queue.drop(q), bl.count}, else: {q, bl.count + 1}
        %{bl | seq: seq, lines: q, count: count}
      end)

    bl = if caught_up, do: %{bl | ready: true}, else: bl
    {:noreply, %{s | bl: bl}}
  end

  @impl true
  def handle_info({:fire, fun}, s) do
    spawn(fun)
    {:noreply, s}
  end

  def handle_info({:EXIT, pid, _reason}, %{bl: %{reader: pid}} = s) do
    {:noreply, %{s | bl: %{s.bl | reader: nil, ready: false, lines: :queue.new(), count: 0}}}
  end

  def handle_info({:EXIT, _pid, _reason}, s), do: {:noreply, s}

  # The reader: Python's _bootlog_reader thread. Its end (normal or not) clears the buffer: the EXIT
  # above. A crash takes the follower's journalctl port with it (the port is linked to this process).
  defp reader(owner) do
    bootlog = Py.mod(:bootlog)
    fmod = Py.mod(:bootlog_follower)
    f = fmod.new(&bootlog.role/0)
    fmod.close(loop(owner, fmod, f))
  end

  defp loop(owner, fmod, f) do
    if Py.monotonic() - GenServer.call(owner, :bootlog_asked) < @bootlog_idle do
      {new, f} = fmod.poll(f, 1.0)
      GenServer.cast(owner, {:bootlog_lines, new, Map.get(f, :caught_up, false)})
      loop(owner, fmod, f)
    else
      f
    end
  end
end
