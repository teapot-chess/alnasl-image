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
  alias AlnaslSetup.Sys
  alias AlnaslSetup.Server.{Box, Py, State}

  @conf "/var/lib/alnasl-setup/displays.conf"
  @outputs "/run/alnasl-kiosk/outputs"
  @drm "/sys/class/drm"
  @layouts ~w(auto single manage mirror two)
  @rotations ~w(normal right inverted left)
  @identify_seconds 8
  @defaults %{"layout" => "auto", "swap" => false, "rotate1" => "normal", "rotate2" => "normal"}

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
      "rotate2" => if(kv["ROTATE2"] in @rotations, do: kv["ROTATE2"], else: "normal")
    }
  end

  @doc "The settings -> the file's text (validated: an ArgumentError is the page's 400)."
  def serialize(%{} = c) do
    c = Map.merge(@defaults, c)
    if c["layout"] not in @layouts, do: raise(ArgumentError, "bad_layout")
    if c["rotate1"] not in @rotations or c["rotate2"] not in @rotations, do: raise(ArgumentError, "bad_rotation")
    if not is_boolean(c["swap"]), do: raise(ArgumentError, "bad_swap")

    "LAYOUT=#{c["layout"]}\nSWAP=#{if c["swap"], do: 1, else: 0}\nROTATE1=#{c["rotate1"]}\nROTATE2=#{c["rotate2"]}\n"
  end

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

    outs = Enum.reject([{o1, w1}, {o2, w2}], fn {o, _} -> o == nil end)

    %{
      "layout" => if(o1, do: lay, else: nil),
      "fallback" => o1 != nil and asked not in ["auto", "single"] and lay == "single",
      "outputs" => for({o, w} <- outs, do: %{"connector" => o, "label" => label(o), "job" => w})
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
      "connected" => for(c <- conn, do: %{"connector" => c, "label" => label(c)}),
      "plan" => plan(conn, cfg),
      "windows" => windows(Sys.read(@outputs, "")),
      "layouts" => @layouts,
      "rotations" => @rotations
    }
  end

  @doc "POST /api/displays: {layout, swap, rotate1, rotate2}; the screens restart with it."
  def set(%{} = b) do
    if Box.running_role() != "nunki", do: raise(ArgumentError, "not_nunki")
    cfg = Map.merge(get(), Map.take(b, ~w(layout swap rotate1 rotate2)))
    Sys.write_atomic(@conf, serialize(cfg), 0o644)
    Py.log("screens: layout #{cfg["layout"]}, swap #{cfg["swap"]}, rotation #{cfg["rotate1"]}/#{cfg["rotate2"]}")
    Box.restart_kiosk()
    %{"ok" => true, "config" => parse(Sys.read(@conf, ""))}
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
