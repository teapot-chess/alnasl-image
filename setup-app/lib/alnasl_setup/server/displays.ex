defmodule AlnaslSetup.Server.Displays do
  @moduledoc """
  A nunki box's screens (v7.5, docs/nunki-displays.md): which layout its HDMI outputs get, which output is the
  first, how each is turned; and "Identify screens", which puts a big number on every output for eight seconds.

  The layout lives in `/var/lib/alnasl-setup/displays.conf` (the data partition: it survives an update), four
  lines the kiosk supervisor (`alnasl-kiosk`) reads word by word, never sources:

      LAYOUT=auto|single|manage|mirror|two
      SWAP=0|1
      ROTATE1=normal|right|inverted|left
      ROTATE2=normal|right|inverted|left

  No file is the same as `auto` with nothing swapped: one monitor shows the broadcast, two show the management
  display on HDMI 0 and the broadcast on HDMI 1. `plan/2` is the kiosk's own rule (kiosk.sh, `nunki_plan`), kept
  here so the wizard can say what will happen before anything restarts; scripts/test-kiosk-logic.sh and
  displays_test.exs check the same table from both ends.

  Which window sits where comes from the kiosk (`/run/alnasl-kiosk/outputs`, written by the X client:
  "n connector job WxH+X+Y" per line); the identify overlay in the kiosk extension matches its own window to it.
  """
  alias AlnaslSetup.{Lock, Sys}
  alias AlnaslSetup.Server.{Box, Py, State}

  @conf "/var/lib/alnasl-setup/displays.conf"
  @outputs "/run/alnasl-kiosk/outputs"
  @drm "/sys/class/drm"
  @layouts ~w(auto single manage mirror two)
  @rotations ~w(normal right inverted left)
  @identify_seconds 8
  @mode_re ~r/\A[0-9]{3,5}x[0-9]{3,5}\z/
  @defaults %{
    "layout" => "auto",
    "swap" => false,
    "rotate1" => "normal",
    "rotate2" => "normal",
    "mode1" => "auto",
    "mode2" => "auto"
  }

  def conf_file, do: @conf
  def layouts, do: @layouts
  def defaults, do: @defaults

  @doc "The file's text -> the settings; anything unknown or missing is the default."
  def parse(text) when is_binary(text) do
    kv =
      for line <- String.split(text, ~r/\r?\n/),
          [k, v] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {String.trim(k), v |> String.trim() |> String.trim("\"")}

    %{
      "layout" => if(kv["LAYOUT"] in @layouts, do: kv["LAYOUT"], else: "auto"),
      "swap" => kv["SWAP"] == "1",
      "rotate1" => if(kv["ROTATE1"] in @rotations, do: kv["ROTATE1"], else: "normal"),
      "rotate2" => if(kv["ROTATE2"] in @rotations, do: kv["ROTATE2"], else: "normal"),
      "mode1" => mode_or_auto(kv["MODE1"]),
      "mode2" => mode_or_auto(kv["MODE2"])
    }
  end

  @doc "The settings -> the file's text (validated: an ArgumentError is the page's 400)."
  def serialize(%{} = c) do
    c = Map.merge(@defaults, c)
    if c["layout"] not in @layouts, do: raise(ArgumentError, "bad_layout")
    if c["rotate1"] not in @rotations or c["rotate2"] not in @rotations, do: raise(ArgumentError, "bad_rotation")
    if not is_boolean(c["swap"]), do: raise(ArgumentError, "bad_swap")
    if not (mode?(c["mode1"]) and mode?(c["mode2"])), do: raise(ArgumentError, "bad_mode")

    "LAYOUT=#{c["layout"]}\nSWAP=#{if c["swap"], do: 1, else: 0}\nROTATE1=#{c["rotate1"]}\nROTATE2=#{c["rotate2"]}\n" <>
      "MODE1=#{c["mode1"]}\nMODE2=#{c["mode2"]}\n"
  end

  @doc "auto or WxH (3 to 5 digits each): what a resolution may be written as."
  def mode?(m), do: m == "auto" or (is_binary(m) and Regex.match?(@mode_re, m))

  defp mode_or_auto(m), do: if(mode?(m), do: m, else: "auto")

  def get, do: parse(Sys.read(@conf, ""))

  @doc """
  What the kiosk does with these connectors (connected HDMI ones, in order) and this layout: the layout it really
  uses and what each output shows ("manage", "hall1", "hall2" or nil = dark). The same rule as kiosk.sh.
  """
  def plan(connected, cfg) do
    {o1, o2} =
      case connected do
        [] -> {nil, nil}
        [a] -> {a, nil}
        [a, b | _] -> if cfg["swap"], do: {b, a}, else: {a, b}
      end

    asked = cfg["layout"] || "auto"
    lay = if asked == "auto", do: if(o2, do: "manage", else: "single"), else: asked
    lay = if o2 == nil, do: "single", else: lay

    {w1, w2} =
      case lay do
        "single" -> {"hall1", nil}
        "manage" -> {"manage", "hall1"}
        "mirror" -> {"hall1", "hall1"}
        "two" -> {"hall1", "hall2"}
      end

    outs =
      Enum.reject([{o1, w1, cfg["mode1"] || "auto"}, {o2, w2, cfg["mode2"] || "auto"}], fn {o, _, _} -> o == nil end)

    %{
      "layout" => if(o1, do: lay, else: nil),
      "fallback" => o1 != nil and asked not in ["auto", "single"] and lay == "single",
      "outputs" => for({o, w, m} <- outs, do: %{"connector" => o, "label" => label(o), "job" => w, "mode" => m})
    }
  end

  @doc "card0-HDMI-A-1 -> \"HDMI 0\": the Pi 4 prints HDMI0 (next to the power socket) and HDMI1 on its case."
  def label(conn) do
    case Regex.run(~r/HDMI-A-(\d+)\z/, conn || "") do
      [_, n] -> "HDMI #{String.to_integer(n) - 1}"
      _ -> conn
    end
  end

  @doc "The connected HDMI connectors, in connector order (sysfs, like the kiosk)."
  def connected do
    case File.ls(Sys.path(@drm)) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/\Acard\d+-HDMI-A-\d+\z/, &1))
        |> Enum.sort()
        |> Enum.filter(&(String.trim(Sys.read("#{@drm}/#{&1}/status")) == "connected"))

      _ ->
        []
    end
  end

  @doc "The kiosk's windows: [%{n, connector, job, x, y, w, h}] (empty: one window, or no kiosk)."
  def windows(text) do
    for line <- String.split(text, "\n"),
        [n, conn, job, g] <- [String.split(String.trim(line), " ")],
        [_, w, h, x, y] <- [Regex.run(~r/\A(\d+)x(\d+)\+(\d+)\+(\d+)\z/, g)] do
      %{
        "n" => String.to_integer(n),
        "connector" => conn,
        "job" => job,
        "x" => String.to_integer(x),
        "y" => String.to_integer(y),
        "w" => String.to_integer(w),
        "h" => String.to_integer(h)
      }
    end
  end

  @doc "GET /api/displays: the settings, the monitors, what the kiosk will do and does."
  def status do
    cfg = get()
    conn = connected()

    %{
      "role" => Box.running_role(),
      "config" => cfg,
      "connected" => for(c <- conn, do: %{"connector" => c, "label" => label(c), "modes" => modes(c)}),
      "plan" => plan(conn, cfg),
      "windows" => windows(Sys.read(@outputs, "")),
      "pending" => pending_status(),
      "layouts" => @layouts,
      "rotations" => @rotations
    }
  end

  @doc "POST /api/displays: {layout, swap, rotate1, rotate2}; the screens restart with it."
  def set(%{} = b) do
    if Box.running_role() != "nunki", do: raise(ArgumentError, "not_nunki")
    cfg = Map.merge(get(), Map.take(b, ~w(layout swap rotate1 rotate2 mode1 mode2)))
    Sys.write_atomic(@conf, serialize(cfg), 0o644)
    Py.log("screens: layout #{cfg["layout"]}, swap #{cfg["swap"]}, rotation #{cfg["rotate1"]}/#{cfg["rotate2"]}")
    Box.restart_kiosk()
    %{"ok" => true, "config" => parse(Sys.read(@conf, ""))}
  end

  # ------------------------------------------------------------------------------- v7.7: live --

  @doc "The progressive modes a connector lists (DRM's modes file), preferred first, each once."
  def modes(conn) do
    "#{@drm}/#{conn}/modes"
    |> Sys.read("")
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@mode_re, &1))
    |> Enum.uniq()
  end

  defp confirm_seconds, do: Py.env(:screens_confirm_seconds, 15)
  @restart_extra 30
  @idle %{timer: nil, token: nil, prev: nil, deadline: 0.0}
  defp pending, do: State.get(:screens_pending, @idle)
  defp put_pending(p), do: State.put(:screens_pending, p)

  @doc """
  What `kiosk-res layout` gets for these settings on these monitors (docs/nunki-displays.md, "Live boards on HDMI"),
  or nil with fewer than two: `[extend|mirror|single, X1, job1, mode1, rot1, X2, job2, mode2, rot2]`. A mode the
  monitor does not list is auto; a mirror gives the second monitor the first one's mode when it has it.
  """
  def layout_args(connected, cfg) do
    p = plan(connected, cfg)

    case p["outputs"] do
      [a, b] ->
        lk = %{"mirror" => "mirror", "single" => "single"}[p["layout"]] || "extend"
        m1 = listed(a["connector"], a["mode"])
        m2 = if lk == "mirror", do: listed(b["connector"], m1), else: listed(b["connector"], b["mode"])
        r1 = cfg["rotate1"] || "normal"
        r2 = if lk == "mirror", do: r1, else: cfg["rotate2"] || "normal"

        [lk, xname(a["connector"]), a["job"] || "off", m1, r1, xname(b["connector"])] ++
          [if(lk == "extend", do: b["job"] || "off", else: "off"), m2, r2]

      _ ->
        nil
    end
  end

  defp listed(_conn, "auto"), do: "auto"
  defp listed(conn, m), do: if(m in modes(conn), do: m, else: "auto")

  # card0-HDMI-A-2 -> HDMI-2 (the modesetting driver's name, as kiosk.sh's xname)
  defp xname(conn), do: conn |> String.replace(~r/\Acard\d+-/, "") |> String.replace("HDMI-A-", "HDMI-")

  # The kiosk lays its two windows out by itself (it runs the two-window client on the modesetting driver: kiosk-res
  # wrote "layout=" into its state) - else a change needs the screens to start again.
  defp live_capable?(n_connected) do
    st = Sys.read(Box.kiosk_state_file(), "")

    Box.unit_state("alnasl-kiosk.service")["active"] and
      if n_connected >= 2,
        do: String.contains?(st, "driver=modesetting") and String.contains?(st, "layout="),
        else: String.contains?(st, "path=x")
  end

  defp exec(args) do
    {rc, out} =
      Sys.run(["docker", "exec", "-e", "DISPLAY=:0", "alnasl-kiosk", "/usr/local/bin/kiosk-res" | args], timeout: 25)

    out = String.trim(out)
    {rc == 0, if(String.length(out) > 400, do: String.slice(out, -400, 400), else: out)}
  end

  # Applies these settings to the running screens: {:live, message} | {:restart, reason}.
  defp relayout(cfg) do
    conn = connected()

    cond do
      conn == [] ->
        {:live, "no monitor connected"}

      not live_capable?(length(conn)) ->
        Box.restart_kiosk()
        {:restart, "the screens start again with it"}

      length(conn) >= 2 ->
        case exec(["layout" | layout_args(conn, cfg)]) do
          {true, msg} -> {:live, msg}
          {false, msg} -> fallback_restart(msg)
        end

      true ->
        [c] = conn
        mode = listed(c, cfg["mode1"] || "auto")

        case exec(["apply", String.replace(c, ~r/\Acard\d+-/, ""), mode, cfg["rotate1"] || "normal"]) do
          {true, msg} -> {:live, msg}
          {false, msg} -> fallback_restart(msg)
        end
    end
  end

  defp fallback_restart(msg) do
    Box.restart_kiosk()
    {:restart, "live change failed (#{msg}); the screens start again with it"}
  end

  @doc """
  Saves the screens' settings (a map of the `get/0` keys, merged into the saved ones) and applies them LIVE, no
  restart: only the windows whose job or place changed start again (kiosk-res layout). A change of resolution must
  be confirmed within 15 seconds (`confirm/0`), or the previous settings come back by themselves, like a desktop's
  display settings; a second change before that keeps the ORIGINAL to go back to. When the kiosk cannot do it live
  (the fbdev fallback, a kiosk that is not laid out by kiosk-res), the screens restart instead, and a resolution
  change then gets 30 seconds more before it must be confirmed.
  """
  def apply_live(%{} = changes) do
    if Box.running_role() != "nunki", do: raise(ArgumentError, "not_nunki")

    Lock.with_lock(fn ->
      cur = get()
      cfg = Map.merge(cur, Map.take(changes, ~w(layout swap rotate1 rotate2 mode1 mode2)))
      text = serialize(cfg)
      p = pending()
      orig = if p.timer != nil, do: p.prev, else: cur
      State.cancel(p.timer)
      Sys.write_atomic(@conf, text, 0o644)
      {how, msg} = relayout(cfg)
      Py.log("screens: #{how}: layout #{cfg["layout"]}, modes #{cfg["mode1"]}/#{cfg["mode2"]} (#{msg})")
      ask? = connected() != [] and {orig["mode1"], orig["mode2"]} != {cfg["mode1"], cfg["mode2"]}

      if ask? do
        # a restart takes a while to show anything: the confirmation window starts after it
        wait = confirm_seconds() + if(how == :restart, do: @restart_extra, else: 0)
        token = make_ref()
        timer = State.timer(wait + 2, fn -> timer_revert(token) end)
        put_pending(%{timer: timer, token: token, prev: orig, deadline: Sys.now() + wait + 2})

        %{
          "ok" => true,
          "live" => how == :live,
          "restart" => how == :restart,
          "pending" => true,
          "confirm_seconds" => wait,
          "message" => msg
        }
      else
        put_pending(@idle)
        %{"ok" => true, "live" => how == :live, "restart" => how == :restart, "pending" => false, "message" => msg}
      end
    end)
  end

  defp timer_revert(token), do: Lock.with_lock(fn -> if pending().token == token, do: revert_now() end)

  defp revert_now do
    prev = pending().prev
    put_pending(@idle)

    if prev != nil do
      Sys.write_atomic(@conf, serialize(prev), 0o644)
      {how, msg} = relayout(prev)
      Py.log("screens: the resolution was not confirmed; back to #{prev["mode1"]}/#{prev["mode2"]} (#{how}: #{msg})")
    end

    :ok
  end

  @doc "Keep: the new resolutions stay."
  def confirm do
    State.cancel(pending().timer)
    put_pending(@idle)
    %{"ok" => true}
  end

  @doc "Undo: the same as the time running out, right now."
  def undo do
    Lock.with_lock(fn ->
      State.cancel(pending().timer)
      revert_now()
    end)

    %{"ok" => true}
  end

  @doc "Whether a change waits for Keep, and how long it still has."
  def pending_status do
    p = pending()

    if p.timer,
      do: %{"pending" => true, "seconds_left" => max(0, trunc(p.deadline - 2 - Sys.now()))},
      else: %{"pending" => false}
  end

  @what %{"manage" => "Management", "hall1" => "Hall screen 1", "hall2" => "Hall screen 2", "mirror" => "Hall screen 1"}

  @doc "POST /api/displays/identify: the numbers go up for eight seconds."
  def identify_start do
    State.put(:identify_until, Sys.now() + @identify_seconds)
    %{"ok" => true, "seconds" => @identify_seconds}
  end

  @doc "GET /api/displays/identify: asked every 1.5 s by every window (identify.js)."
  def identify do
    left = State.get(:identify_until, 0.0) - Sys.now()

    if left > 0 do
      outs =
        for w <- windows(Sys.read(@outputs, "")),
            do: Map.merge(w, %{"what" => "#{label(hdmi_conn(w["connector"]))}: #{@what[w["job"]] || w["job"]}"})

      single =
        case connected() do
          [c | _] -> "#{label(c)}: #{@what["hall1"]}"
          _ -> ""
        end

      %{"active" => true, "left" => Float.round(left, 1), "outputs" => outs, "single" => single}
    else
      %{"active" => false}
    end
  end

  # the X name (HDMI-2) back to a connector name the label understands
  defp hdmi_conn("HDMI-" <> n), do: "HDMI-A-" <> n
  defp hdmi_conn(other), do: other
end
