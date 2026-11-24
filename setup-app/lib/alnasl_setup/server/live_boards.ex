defmodule AlnaslSetup.Server.LiveBoards do
  @moduledoc """
  v7.7, "Live boards on HDMI" (docs/nunki-displays.md): the touch panel's wizard that puts OpenResults' live boards on
  a nunki box's monitors - which tournament, which boards on which monitor (or the same as the first, or nothing),
  each monitor's resolution - and applies it all without a restart.

  The work is split where it already lives:

    * what a hall screen shows is Nunki's (local API: `hall_tournament`, and `screen_source` with the `boards`
      source of Nunki 0.9.0, which frames `<results>/live/current/projector?boards=..&kiosk=1`, follows the round
      and survives a restart in Nunki's own state);
    * which monitor shows which hall screen, and at what resolution, is the box's (`Displays`: displays.conf, laid
      out live by `kiosk-res layout`, a resolution kept only once confirmed).

      GET  /api/liveboards        {"displays": Displays.status(), "nunki": Nunki.state()}
      POST /api/liveboards        {"tournament": id | null,
                                   "screens": [{"show": "boards" | "hall", "boards": "1-4"},
                                               {"show": "boards" | "hall" | "mirror" | "off", "boards": "5-10"}],
                                   "modes": ["auto" | "WxH", "auto" | "WxH"]}
      POST /api/liveboards/keep   the new resolutions stay
      POST /api/liveboards/undo   back to the previous ones now

  Screen 1 is the first monitor (HDMI 0, or HDMI 1 when the screens are swapped), screen 2 the other. `tournament`
  null is Nunki's own pick (whatever is playing). One monitor: only the first entry counts.
  """
  alias AlnaslSetup.Server.{Box, Displays, Nunki}

  @shows1 ~w(boards hall)
  @shows2 ~w(boards hall mirror off)

  def status, do: %{"displays" => Displays.status(), "nunki" => Nunki.state()}

  @doc "Which layout (displays.conf) the wizard's two answers mean with this many monitors."
  def layout(n_connected, show2) do
    cond do
      n_connected < 2 -> "single"
      show2 == "off" -> "single"
      show2 == "mirror" -> "mirror"
      true -> "two"
    end
  end

  def apply(%{} = b) do
    if Box.running_role() != "nunki", do: raise(ArgumentError, "not_nunki")

    {s1, s2} =
      case b["screens"] do
        [%{} = a, %{} = c | _] -> {a, c}
        [%{} = a] -> {a, %{"show" => "off"}}
        _ -> raise ArgumentError, "bad_screens"
      end

    if s1["show"] not in @shows1 or s2["show"] not in @shows2, do: raise(ArgumentError, "bad_show")

    for s <- [s1, s2], s["show"] == "boards", do: check_boards(s["boards"])

    tid = b["tournament"]
    if not (is_nil(tid) or is_binary(tid) or is_integer(tid)), do: raise(ArgumentError, "bad_id")

    {m1, m2} =
      case b["modes"] do
        [x, y | _] -> {x, y}
        [x] -> {x, "auto"}
        _ -> {"auto", "auto"}
      end

    if not (Displays.mode?(m1) and Displays.mode?(m2)), do: raise(ArgumentError, "bad_mode")

    lay = layout(length(Displays.connected()), s2["show"])
    halls = if lay == "two", do: [{"hdmi1", s1}, {"hdmi2", s2}], else: [{"hdmi1", s1}]

    # Nunki first: the windows the layout brings up then open on the right page at once
    problems =
      Enum.flat_map(halls, fn {sc, s} ->
        t = Nunki.set_tournament(%{"screen" => sc, "id" => tid})

        src =
          if s["show"] == "boards",
            do: Nunki.set_source(%{"screen" => sc, "source" => "boards", "boards" => s["boards"] || ""}),
            else: Nunki.set_source(%{"screen" => sc, "source" => "hall"})

        for r <- [t, src], r["ok"] != true, do: Map.put(r, "screen", sc)
      end)

    shown = Displays.apply_live(%{"layout" => lay, "mode1" => m1, "mode2" => m2})
    Map.merge(shown, %{"layout" => lay, "nunki" => problems})
  end

  defp check_boards(sel) when is_nil(sel), do: :ok

  defp check_boards(sel) do
    case Nunki.boards(sel) do
      {:ok, _} -> :ok
      :error -> raise ArgumentError, "bad_boards"
    end
  end
end
