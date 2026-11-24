defmodule AlnaslSetup.Server.Nunki do
  @moduledoc """
  The touch panel's Nunki controls (v7.5, docs/nunki-displays.md), through Nunki's local API v1 on the loopback
  (Nunki answers 403 to anything else):

      GET  /api/local/v1/state           {"screen", "audio", "hall_tournament", "tournaments": [{id, name, connected}],
                                          "countdown", "version", "screens": {"hdmi1": {mode, tournament}, "hdmi2": ...}}
      POST /api/local/v1/screen          {"screen": "hdmi1"|"hdmi2", "mode": "live"|"paused"|"black"}
      POST /api/local/v1/audio           {"enabled": bool}
      POST /api/local/v1/hall_tournament {"screen": "hdmi1"|"hdmi2", "id": id|null}
      POST /api/local/v1/screen_source     {"screen": "hdmi1"|"hdmi2", "source": "hall"|"web", "url": "https://..."} (Nunki 0.8.0+;
                                          "screens.<n>" then also has "source" and "url"; a 404 is "old", a 422 carries its sentence)
                                         {"source": "boards", "boards": "1-4"} (Nunki 0.9.0+: OpenResults' live boards of the
                                          screen's tournament, following the round; "screens.<n>" has "boards" and "boards_url",
                                          each tournament its OpenResults address "results", null when it is not published)

  A Nunki without "screens" (the first v1) has one hall screen: the top-level "screen" and "hall_tournament" are
  hdmi1's, and hdmi2 is reported as not there. A Nunki older than the API answers 404: that is said plainly
  ("old"), as is one that does not answer at all ("down"). Nothing here retries or caches: the panel asks every
  few seconds anyway.
  """
  alias AlnaslSetup.Json
  alias AlnaslSetup.Server.Py

  @screens ~w(hdmi1 hdmi2)
  @modes ~w(live paused black)
  @sources ~w(hall web boards)
  # Nunki's own grammar (0.9.0): empty = every board, else N or N-M items, comma-separated. Nunki has the last word.
  @boards_re ~r/\A(\d{1,3}(-\d{1,3})?(,\d{1,3}(-\d{1,3})?){0,19})?\z/
  @timeout 3000

  defp base, do: Py.env(:nunki_url, "http://127.0.0.1:4062")

  defp request(method, path, body \\ nil) do
    url = to_charlist(base() <> "/api/local/v1" <> path)
    hdrs = [{~c"accept", ~c"application/json"}]
    opts = [timeout: @timeout, connect_timeout: 1000, autoredirect: false]

    req =
      if method == :get,
        do: {url, hdrs},
        else: {url, hdrs, ~c"application/json", Json.encode(body)}

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, _h, resp}} -> {status, resp}
      {:error, _} -> :down
    end
  end

  @doc "GET /api/nunki: `%{ok: true, state}` or `%{ok: false, reason: down|old|refused|bad}`."
  def state do
    case request(:get, "/state") do
      :down -> %{"ok" => false, "reason" => "down"}
      {404, _} -> %{"ok" => false, "reason" => "old"}
      {403, _} -> %{"ok" => false, "reason" => "refused"}
      {200, body} -> answer(Json.decode_or_nil(body))
      {status, _} -> %{"ok" => false, "reason" => "bad", "status" => status}
    end
  end

  defp answer(%{} = s), do: %{"ok" => true, "state" => normalize(s)}
  defp answer(_), do: %{"ok" => false, "reason" => "bad"}

  @doc "Nunki's state as the panel reads it: always a `screens` map (hdmi1, and hdmi2 when Nunki has one)."
  def normalize(%{} = s) do
    screens =
      case s["screens"] do
        %{} = m ->
          for {k, %{} = v} <- m, k in @screens, into: %{}, do: {k, screen(v["mode"], v["tournament"], v)}

        _ ->
          %{"hdmi1" => screen(s["screen"], s["hall_tournament"], s)}
      end

    tournaments =
      for %{} = t <- List.wrap(s["tournaments"]),
          do: %{
            "id" => t["id"],
            "name" => name(t),
            "connected" => t["connected"] == true,
            "results" => str(t["results"])
          }

    %{
      "screens" => screens,
      "two_screens" => Map.has_key?(screens, "hdmi2"),
      "audio" => s["audio"] == true,
      "tournaments" => tournaments,
      "countdown" => if(is_map(s["countdown"]), do: s["countdown"], else: nil),
      "version" => if(is_binary(s["version"]), do: s["version"], else: nil)
    }
  end

  defp name(t), do: if(is_binary(t["name"]) and t["name"] != "", do: t["name"], else: to_string(t["id"]))

  # "source" is nil on a Nunki before 0.8.0: the panel then offers no source choice
  defp screen(mode, t, v) do
    %{
      "mode" => if(mode in @modes, do: mode, else: "live"),
      "tournament" => t,
      "source" => if(v["source"] in @sources, do: v["source"], else: nil),
      "url" => if(is_binary(v["url"]), do: v["url"], else: nil),
      # Nunki 0.9.0+: the live boards' selection ("" = all) and the page they come from (nil: not on OpenResults)
      "boards" => str(v["boards"]),
      "boards_url" => str(v["boards_url"]),
      "shows" => v["shows"]
    }
  end

  defp str(v), do: if(is_binary(v), do: v, else: nil)

  @doc "A board selection as Nunki takes it (spaces dropped): `{:ok, selection}` or `:error`."
  def boards(sel) when is_binary(sel) do
    sel = String.replace(sel, " ", "")
    if byte_size(sel) <= 100 and Regex.match?(@boards_re, sel), do: {:ok, sel}, else: :error
  end

  def boards(_other), do: :error

  @doc "POST /api/nunki/screen {screen, mode}"
  def set_screen(%{} = b) do
    sc = b["screen"] || "hdmi1"
    if sc not in @screens, do: raise(ArgumentError, "bad_screen")
    if b["mode"] not in @modes, do: raise(ArgumentError, "bad_mode")
    post("/screen", %{"screen" => sc, "mode" => b["mode"]})
  end

  @doc "POST /api/nunki/audio {enabled}"
  def set_audio(%{} = b) do
    if not is_boolean(b["enabled"]), do: raise(ArgumentError, "bad_enabled")
    post("/audio", %{"enabled" => b["enabled"]})
  end

  @doc "POST /api/nunki/tournament {screen, id}; id null = Nunki's own choice."
  def set_tournament(%{} = b) do
    sc = b["screen"] || "hdmi1"
    if sc not in @screens, do: raise(ArgumentError, "bad_screen")
    id = b["id"]
    if not (is_nil(id) or is_binary(id) or is_integer(id)), do: raise(ArgumentError, "bad_id")
    post("/hall_tournament", %{"screen" => sc, "id" => id})
  end

  @doc """
  POST /api/nunki/source {screen, source, url | boards}: url only for web (optional when the screen has one), boards
  only for boards (optional: the screen keeps its selection; "" is every board).
  """
  def set_source(%{} = b) do
    sc = b["screen"] || "hdmi1"
    if sc not in @screens, do: raise(ArgumentError, "bad_screen")
    if b["source"] not in @sources, do: raise(ArgumentError, "bad_source")
    url = b["url"]
    if not (is_nil(url) or (is_binary(url) and byte_size(url) <= 2000)), do: raise(ArgumentError, "bad_url")
    body = %{"screen" => sc, "source" => b["source"]}

    body =
      case {b["source"], b["boards"]} do
        {"web", _} when is_binary(url) ->
          Map.put(body, "url", url)

        {"boards", sel} when sel != nil ->
          case boards(sel) do
            {:ok, sel} -> Map.put(body, "boards", sel)
            :error -> raise ArgumentError, "bad_boards"
          end

        _ ->
          body
      end

    post("/screen_source", body, true)
  end

  # sentence: a 422 from Nunki says why in a sentence made to be shown; the caller may pass it on
  defp post(path, body, sentence \\ false) do
    case request(:post, path, body) do
      :down -> %{"ok" => false, "reason" => "down"}
      {404, _} -> %{"ok" => false, "reason" => "old"}
      {422, r} when sentence -> refused(r)
      {422, _} -> %{"ok" => false, "reason" => "refused"}
      {s, _} when s in 200..299 -> %{"ok" => true}
      {s, _} -> %{"ok" => false, "reason" => "bad", "status" => s}
    end
  end

  defp refused(resp) do
    case Json.decode_or_nil(resp) do
      %{"error" => e} when is_binary(e) -> %{"ok" => false, "reason" => "refused", "message" => String.slice(e, 0, 300)}
      _ -> %{"ok" => false, "reason" => "refused"}
    end
  end
end
