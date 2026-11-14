defmodule AlnaslSetup.Server.Nunki do
  @moduledoc """
  The touch panel's Nunki controls (v7.5, docs/nunki-displays.md), through Nunki's local API v1 on the loopback
  (Nunki answers 403 to anything else):

      GET  /api/local/v1/state           {"screen", "audio", "hall_tournament", "tournaments": [{id, name, connected}],
                                          "countdown", "version", "screens": {"hdmi1": {mode, tournament}, "hdmi2": ...}}
      POST /api/local/v1/screen          {"screen": "hdmi1"|"hdmi2", "mode": "live"|"paused"|"black"}
      POST /api/local/v1/audio           {"enabled": bool}
      POST /api/local/v1/hall_tournament {"screen": "hdmi1"|"hdmi2", "id": id|null}

  A Nunki without "screens" (the first v1) has one hall screen: the top-level "screen" and "hall_tournament" are
  hdmi1's, and hdmi2 is reported as not there. A Nunki older than the API answers 404: that is said plainly
  ("old"), as is one that does not answer at all ("down"). Nothing here retries or caches: the panel asks every
  few seconds anyway.
  """
  alias AlnaslSetup.Json
  alias AlnaslSetup.Server.Py

  @screens ~w(hdmi1 hdmi2)
  @modes ~w(live paused black)
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
          for {k, %{} = v} <- m, k in @screens, into: %{}, do: {k, screen(v["mode"], v["tournament"])}

        _ ->
          %{"hdmi1" => screen(s["screen"], s["hall_tournament"])}
      end

    tournaments =
      for %{} = t <- List.wrap(s["tournaments"]),
          do: %{"id" => t["id"], "name" => name(t), "connected" => t["connected"] == true}

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

  defp screen(mode, t), do: %{"mode" => if(mode in @modes, do: mode, else: "live"), "tournament" => t}

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

  defp post(path, body) do
    case request(:post, path, body) do
      :down -> %{"ok" => false, "reason" => "down"}
      {404, _} -> %{"ok" => false, "reason" => "old"}
      {422, _} -> %{"ok" => false, "reason" => "refused"}
      {s, _} when s in 200..299 -> %{"ok" => true}
      {s, _} -> %{"ok" => false, "reason" => "bad", "status" => s}
    end
  end
end
