defmodule AlnaslSetup.Bootlog do
  @moduledoc """
  What the boot screen may show of the box's log (v7, docs/v7-plan.md section 2).

  The boot screen stands in a public hall, so this is an allow-list, not a filter of bad things:

    * the kernel, at info level or more urgent;
    * systemd's own lines about the units below, and any of its warnings or failures;
    * the units below (the box's own, the network, docker, the four role apps, CUPS), info or more urgent.

  Every line then goes through `redact/1`: anything that looks like a secret becomes `***`. What is left is
  made ASCII (the screen's glyph atlas has nothing else) and cut to a screen's width.

  Used by the framebuffer painter (`AlnaslSetup.Splash`, until X starts) and by the setup server's
  /api/bootlog (the browser's /boot page after that), so both show the same lines in the same order: the
  hand-over is seamless. No state of its own; `AlnaslSetup.Bootlog.Follower` follows the journal.
  """

  alias AlnaslSetup.Sys

  # ------------------------------------------------------------------ redaction --
  # Generous on purpose: a word too many on the screen is a secret in a photo of the hall.
  @keys ~S"(?:psk|wpa_passphrase|passphrase|passwd|password|pass|pwd|sae_password|wep_key\d?|private_key\w*|" <>
          ~S"secret\w*|client_secret|token\w*|access_token|refresh_token|api[_-]?key|apikey|key|keys|auth\w*|" <>
          ~S"cookie\w*|set-cookie|session\w*|sid|csrf\w*|bearer|signature|sig|otp|pin|code|join(?:_?link)?|" <>
          ~S"identity|anonymous_identity|credential\w*)"

  # {pattern, replacement}, applied in this order. The patterns are PCRE with the unicode flag, which makes
  # \b \d \s \w unicode-aware like Python 3's re does for str patterns. Compiled once (a regex cannot live in
  # a module attribute on OTP 28 and later), kept in :persistent_term.
  defp rule_sources do
    [
      # key=value, key: value, JSON "key": "value" (systemd's own "code=exited" says how a unit ended, and stays)
      {"(?i)(\"?\\b" <>
         @keys <> "\\b\"?\\s*[=:]\\s*)(?!(?:exited|killed|dumped)\\b)(\"[^\"]*\"|'[^']*'|[^\\s,;]+)", "\\1***"},
      # a query string on a bare path (a request log line: GET /join?t=...)
      {~S"(\s/[^\s?#]*)\?\S+", "\\1?***"},
      {~S"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{6,}", "\\1 ***"},
      {~S"(?i)(authorization\s*[:=]?\s*)\S.*$", "\\1***"},
      {"(?i)(wpa_passphrase\\s+(?:\"[^\"]*\"|\\S+)\\s+)\\S+", "\\1***"},
      # credentials and queries in URLs: scheme://user:pass@host/...?a=b
      {~S"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s@]+@", "\\1***@"},
      {~S"(?i)(\b[a-z][a-z0-9+.-]*://[^\s?#]*)[?#]\S*", "\\1?***"},
      # e-mail addresses: the name goes
      {~S"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.[A-Za-z0-9.-]+)\b", "***@\\1"},
      # long hex (keys, machine ids, hashes) and token-looking runs (mixed case and digits, 20+)
      {~S"\b[0-9a-fA-F]{16,}\b", "***"},
      {~S"(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+/=-]*\d)(?=[A-Za-z0-9_+/=-]*[a-z])(?=[A-Za-z0-9_+/=-]*[A-Z])" <>
         ~S"[A-Za-z0-9_+/=-]{20,}", "***"},
      # JWTs
      {~S"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+", "***"},
      # support codes and the like: any number of exactly six digits, alone or as 123 456 / 123-456
      {~S"(?<![\d.:])\d{3}[ -]?\d{3}(?![\d.:])", "***"}
    ]
  end

  defp rules do
    case :persistent_term.get({__MODULE__, :rules}, nil) do
      nil ->
        r = for {src, rep} <- rule_sources(), do: {Regex.compile!(src, "u"), rep}
        :persistent_term.put({__MODULE__, :rules}, r)
        r

      r ->
        r
    end
  end

  def redact(text) do
    text = Enum.reduce(rules(), text, fn {rx, rep}, acc -> Regex.replace(rx, acc, rep) end)

    # The box's access PIN itself, whatever it looks like (a typed one need not be six digits). Nothing is
    # meant to print it; this is for the thing that does anyway.
    case AlnaslSetup.Server.Pin.copy_pin() do
      pin when is_binary(pin) and byte_size(pin) >= 4 -> String.replace(text, pin, "***")
      _ -> text
    end
  end

  @doc "Printable ASCII only (the glyph atlas has nothing else); tabs and controls become spaces."
  def ascii_line(text, width \\ 240) do
    s =
      for(<<c::utf8 <- text>>, into: "", do: ascii_char(c))
      |> String.replace(~r/ {2,}/, " ")
      |> String.trim(" ")

    if String.length(s) <= width, do: s, else: String.slice(s, 0, width - 3) <> "..."
  end

  defp ascii_char(c) when c >= 32 and c < 127, do: <<c>>
  defp ascii_char(c) when c in [?\t, ?\r, ?\n], do: " "
  defp ascii_char(c), do: Map.get(fold(), c, "?")

  # Accented letters to their plain ones, typographic punctuation to ASCII; everything else is "?".
  defp fold do
    letters =
      for {chars, to} <- [
            {"àáâãäå", "a"},
            {"èéêë", "e"},
            {"ìíîï", "i"},
            {"òóôõö", "o"},
            {"ùúûü", "u"},
            {"ç", "c"},
            {"ñ", "n"},
            {"ÀÁÂÃÄÅ", "A"},
            {"ÈÉÊË", "E"},
            {"ÌÍÎÏ", "I"},
            {"ÒÓÔÕÖ", "O"},
            {"ÙÚÛÜ", "U"},
            {"Ç", "C"},
            {"Ñ", "N"}
          ],
          <<c::utf8 <- chars>>,
          into: %{},
          do: {c, to}

    Map.merge(letters, %{
      0x2018 => "'",
      0x2019 => "'",
      0x201C => "\"",
      0x201D => "\"",
      0x2013 => "-",
      0x2014 => "-",
      0x2026 => "...",
      0xB7 => "-",
      0x2192 => "->",
      0xA0 => " "
    })
  end

  # ----------------------------------------------------------------- allow-list --
  @net_units MapSet.new(~w(systemd-networkd.service systemd-resolved.service systemd-timesyncd.service
                           wpa_supplicant@wlan0.service alnasl-wifi.service alnasl-firewall.service))
  @app_units [
    {"alnasl", ~w(alnasl.service alnasl-update.service)},
    {"arkab", ~w(arkab.service arkab-update.service)},
    {"polis", ~w(polis.service polis-update.service cups.service)},
    {"nunki", ~w(nunki.service nunki-update.service alnasl-sound.service)}
  ]
  # v7.3: the hotspot's lines say when it goes on and off; never its password
  @box_units MapSet.new(~w(docker.service containerd.service alnasl-setup.service alnasl-data.service
                           alnasl-mode.service alnasl-firstboot.service alnasl-kiosk.service
                           alnasl-kiosk-load.service alnasl-slot-check.service alnasl-upgrade-boot.service
                           alnasl-os-update.service alnasl-system-update.service
                           alnasl-system-update-check.service alnasl-reset-boot.service alnasl-hotspot.service))
  @all_apps MapSet.new(Enum.flat_map(@app_units, &elem(&1, 1)))
  @allowed @net_units |> MapSet.union(@all_apps) |> MapSet.union(@box_units)

  # What the status line counts, per role: the box's own units, then the role's.
  @base_expect ~w(alnasl-data.service alnasl-mode.service alnasl-firewall.service systemd-networkd.service
                  systemd-resolved.service alnasl-setup.service containerd.service docker.service
                  alnasl-kiosk-load.service alnasl-kiosk.service)
  @role_expect %{
    "alnasl" => ["alnasl.service"],
    "arkab" => ["arkab.service"],
    "polis" => ["cups.service", "polis.service"],
    "nunki" => ["alnasl-sound.service", "nunki.service"]
  }

  @doc "The journalctl command that follows this boot, with only the fields the allow-list reads."
  def journalctl_argv do
    fields = ~w(MESSAGE PRIORITY _TRANSPORT _SYSTEMD_UNIT _PID SYSLOG_IDENTIFIER UNIT USER_UNIT)
    ["journalctl", "-b", "-f", "--no-tail", "-o", "json", "--output-fields=" <> Enum.join(fields, ",")]
  end

  # A journal field as text; anything else (absent, null, a list of bytes) counts as empty.
  defp text_field(e, k) do
    case Map.get(e, k) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp priority(e) do
    case Map.get(e, "PRIORITY", "6") do
      p when is_integer(p) ->
        p

      p when is_float(p) ->
        trunc(p)

      p when is_binary(p) ->
        case Integer.parse(String.trim(p)) do
          {n, ""} -> n
          _ -> 6
        end

      _ ->
        6
    end
  end

  @doc "A journal entry (map of its JSON fields) -> `{tag, colour, error?}` or nil when it is not shown."
  def classify(e, role) do
    prio = priority(e)

    cond do
      # debug: never
      prio > 6 ->
        nil

      Map.get(e, "_TRANSPORT") == "kernel" ->
        {"kernel", if(prio <= 3, do: "error", else: "kernel"), prio <= 3}

      Map.get(e, "_PID") == "1" ->
        about = first_present(text_field(e, "UNIT"), text_field(e, "USER_UNIT"))
        msg = Map.get(e, "MESSAGE")
        text = if is_binary(msg), do: msg, else: ""
        failed = prio <= 4 or String.contains?(text, "ailed") or String.contains?(text, "rror")

        if not failed and not MapSet.member?(@allowed, about) and not String.ends_with?(about, ".target") do
          nil
        else
          {"systemd", if(failed, do: "error", else: "systemd"), failed}
        end

      true ->
        unit = text_field(e, "_SYSTEMD_UNIT")
        err = prio <= 3

        cond do
          not MapSet.member?(@allowed, unit) ->
            nil

          MapSet.member?(@net_units, unit) ->
            {"network", if(err, do: "error", else: "network"), err}

          MapSet.member?(@all_apps, unit) ->
            {tag, _} = Enum.find(@app_units, fn {_, us} -> unit in us end)
            {tag, if(err, do: "error", else: if(tag == role, do: "app", else: "box")), err}

          true ->
            tag = unit |> String.replace(".service", "") |> String.replace("alnasl-", "") |> String.slice(0, 10)
            {tag, if(err, do: "error", else: "box"), err}
        end
    end
  end

  defp first_present("", b), do: b
  defp first_present(a, _), do: a

  @doc "`{tag, colour, error?, text}` or nil."
  def entry_line(e, role) when is_map(e) do
    case classify(e, role) do
      nil ->
        nil

      {tag, colour, err} ->
        case message(Map.get(e, "MESSAGE")) do
          nil ->
            nil

          msg ->
            text = msg |> redact() |> ascii_line()
            if text == "", do: nil, else: {tag, colour, err, text}
        end
    end
  end

  def entry_line(_, _), do: nil

  # journald gives bytes as a list of numbers
  defp message(msg) when is_list(msg) do
    if msg != [] and Enum.all?(msg, &(is_integer(&1) and &1 >= 0 and &1 <= 255)) do
      msg |> :erlang.list_to_binary() |> String.replace_invalid() |> message()
    else
      # an empty list is an empty message; anything else is not bytes
      nil
    end
  end

  defp message(msg) when is_binary(msg), do: if(String.trim(msg) == "", do: nil, else: msg)
  defp message(_), do: nil

  def format_line(tag, text), do: String.pad_trailing(String.slice(tag, 0, 8), 8) <> " " <> text

  # --------------------------------------------------------------------- status --
  @role_file "/run/alnasl-mode/role"
  @props "Id,ActiveState,SubState,Result,Type,UnitFileState,InactiveEnterTimestampMonotonic"

  def role do
    r = @role_file |> Sys.read("") |> String.trim()
    if Map.has_key?(@role_expect, r), do: r, else: "alnasl"
  end

  @doc "`systemctl show` of the units as `%{id => %{property => value}}`."
  def unit_states(units) do
    {_rc, out} = Sys.run(["systemctl", "show", "-p", @props | units], timeout: 5)

    {res, _} =
      Enum.reduce(String.split(out, "\n") ++ [""], {%{}, %{}}, fn line, {res, cur} ->
        if String.trim(line) == "" do
          case Map.get(cur, "Id") do
            id when id not in [nil, ""] -> {Map.put(res, id, cur), %{}}
            _ -> {res, %{}}
          end
        else
          case String.split(line, "=", parts: 2) do
            [k, v] -> {res, Map.put(cur, k, v)}
            [k] -> {res, Map.put(cur, k, "")}
          end
        end
      end)

    res
  end

  @doc "`{up, expected, failed}` over the units that are meant to run (enabled, or running anyway)."
  def count(states, units) do
    Enum.reduce(units, {0, 0, 0}, fn u, {up, exp, failed} ->
      s = Map.get(states, u)

      if s == nil or s == %{} do
        {up, exp, failed}
      else
        act = s["ActiveState"]

        if s["UnitFileState"] not in ["enabled", "static", "enabled-runtime", "alias"] and
             act not in ["active", "activating", "failed"] do
          {up, exp, failed}
        else
          cond do
            act == "active" or
                (s["Type"] == "oneshot" and act == "inactive" and s["Result"] == "success" and
                   Map.get(s, "InactiveEnterTimestampMonotonic", "0") not in ["", "0"]) ->
              {up + 1, exp + 1, failed}

            act == "failed" ->
              {up, exp + 1, failed + 1}

            true ->
              {up, exp + 1, failed}
          end
        end
      end
    end)
  end

  def status_text(r, lang, up, exp, failed) do
    all? = exp != 0 and up == exp

    if lang == "nl" do
      s = if all?, do: "#{r} staat klaar", else: "#{r} starten - #{up} van #{exp} actief"
      s <> if(failed != 0, do: ", #{failed} mislukt", else: "")
    else
      s = if all?, do: "#{r} is up", else: "starting #{r} - #{up} of #{exp} up"
      s <> if(failed != 0, do: ", #{failed} failed", else: "")
    end
  end

  @doc "`%{\"role\", \"up\", \"expected\", \"failed\", \"text\"}` (string keys: it goes to the browser as JSON)."
  def status(lang) do
    r = role()
    units = @base_expect ++ Map.fetch!(@role_expect, r)
    {up, exp, failed} = count(unit_states(units), units)
    %{"role" => r, "up" => up, "expected" => exp, "failed" => failed, "text" => status_text(r, lang, up, exp, failed)}
  end
end
