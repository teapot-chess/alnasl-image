defmodule AlnaslSetup.Server.Box do
  @moduledoc """
  The setup server's view of the box (was most of server.py): its state file, the units, the role,
  the keyboard, the kiosk settings, the page heartbeat, system information, sound, the console, the
  boot screen and the system updates. Everything goes through `AlnaslSetup.Sys` (box paths, commands as
  argument lists, never a shell line). A validation error raises `ArgumentError` with the text the page
  shows.
  """
  alias AlnaslSetup.{Diag, Json, Lock, Sys, Wifi}
  alias AlnaslSetup.Server.{Net, Py, State}

  @state_dir "/var/lib/alnasl-setup"
  @done @state_dir <> "/done"
  @state_json @state_dir <> "/state.json"
  @kbd_conf "/etc/alnasl/keyboard.conf"
  @kiosk_conf "/etc/alnasl/kiosk.conf"
  @kiosk_state "/run/alnasl-kiosk/state"
  @alnasl_port 4040

  # v6 boot screen: what the box is doing ("reset-2", "update-os", ...), written by alnasl-splash and
  # the scripts that call it; the pictures of each state, the same ones the framebuffer painter shows.
  @screen_state "/run/alnasl-screen/state"
  # "37%", "v6.2": the update states' value line
  @screen_value "/run/alnasl-screen/value"
  # 0-100: their bar
  @screen_progress "/run/alnasl-screen/progress"
  @splash "/usr/share/alnasl/splash"

  @kiosk_run "/run/alnasl-kiosk"
  # "<unix time>\t<page>"; read by the kiosk watchdog too
  @ping_file @kiosk_run <> "/ping"
  # a menu page pings every 8 s; this is "open" for the watchdog
  @busy_seconds 35
  # a page seen this recently is where a restarted browser returns to
  @resume_seconds 180
  @menu_pages ~w(/menu /settings /info /diag /help /setup)

  # (id, label, X layout, X variant, console keymap candidates in order of preference)
  @layouts [
    {"be", "Belgian (AZERTY)", "be", "", ["be-latin1"]},
    {"fr", "French (AZERTY)", "fr", "", ["fr-latin9", "fr-latin1", "fr"]},
    {"nl", "Dutch", "nl", "", ["nl", "nl2"]},
    {"us-intl", "US international", "us", "intl", ["us-acentos", "us"]},
    {"de", "German (QWERTZ)", "de", "", ["de-latin1-nodeadkeys", "de-latin1", "de"]},
    {"us", "US (QWERTY)", "us", "", ["us"]},
    {"gb", "British", "gb", "", ["uk"]},
    {"es", "Spanish", "es", "", ["es"]},
    {"it", "Italian", "it", "", ["it"]},
    {"pt", "Portuguese", "pt", "", ["pt-latin1", "pt"]}
  ]

  @mode_file @state_dir <> "/mode"
  # what alnasl-mode started this boot as (v7 word)
  @role_run "/run/alnasl-mode/role"
  # v7: four roles (docs/v7-plan.md section 1). v6's two words still mean the first two, everywhere.
  @roles ~w(alnasl arkab polis nunki)
  @aliases %{"master" => "alnasl", "slave" => "arkab"}
  @legacy %{"alnasl" => "master", "arkab" => "slave"}
  # The page each role shows on the box's screen; its port answering is "up".
  @role_port %{"alnasl" => 4040, "arkab" => 4050, "polis" => 4061, "nunki" => 4062}

  def state_dir, do: @state_dir
  def done_file, do: @done
  def kiosk_state_file, do: @kiosk_state
  def splash, do: @splash
  def role_port, do: @role_port
  def layouts, do: @layouts

  # ---------------------------------------------------------------------------------- writing --

  @doc """
  Writes a root-only file (0600) so that nobody else ever sees it, not even for a moment: a fresh 0700
  directory beside it, the file created there, made 0600, renamed into place. Nothing is created at a
  predictable name, so a symlink planted there is never followed (Python's O_NOFOLLOW on the .new
  name). Options: `follow: true` replaces the file a symlink at `p` points at (write_atomic's
  realpath), `owner: {uid, gid}` gives it to that user before it is moved into place.
  """
  def write_private(p, data, opts \\ []) do
    full = Sys.path(p)
    full = if opts[:follow], do: Sys.realpath(full), else: full
    dir = Path.dirname(full)
    File.mkdir_p!(dir)
    tmpdir = Path.join(dir, ".#{Path.basename(full)}.#{System.unique_integer([:positive])}.tmp")
    File.mkdir!(tmpdir)

    try do
      File.chmod!(tmpdir, 0o700)
      tmp = Path.join(tmpdir, "f")
      File.write!(tmp, data, [:exclusive])
      File.chmod!(tmp, 0o600)

      case opts[:owner] do
        {uid, gid} ->
          File.chown!(tmp, uid)
          File.chgrp!(tmp, gid)

        nil ->
          :ok
      end

      File.rename!(tmp, full)
    after
      File.rm_rf(tmpdir)
    end

    :ok
  end

  def read_json(p) do
    case Json.decode_or_nil(Sys.read(p, "null")) do
      %{} = m -> m
      _ -> nil
    end
  end

  def write_json_private(p, obj), do: write_private(p, Json.encode(obj) <> "\n", follow: true)

  # ------------------------------------------------------------------------------------ state --

  def get_state do
    case Json.decode_or_nil(Sys.read(@state_json, "{}")) do
      %{} = s -> s
      _ -> %{}
    end
  end

  def set_state(kv), do: Sys.write_atomic(@state_json, Json.encode(Map.merge(get_state(), Map.new(kv))))

  def lang, do: Map.get(get_state(), "lang", "en")

  def setup_done?, do: Sys.exists?(@done)

  def sysctl(args), do: Sys.run(["systemctl" | args], timeout: 60)

  def unit_state(u) do
    en = Sys.run(["systemctl", "is-enabled", u]) |> elem(1) |> String.trim()
    ac = Sys.run(["systemctl", "is-active", u]) |> elem(1) |> String.trim()
    %{"enabled" => en == "enabled", "active" => ac == "active"}
  end

  @doc "Something answers on 127.0.0.1:port (one second). The tests map ports through `:connect_ports`."
  def port_up?(port) do
    port = Map.get(Py.env(:connect_ports, %{}), port, port)

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      {:error, _} ->
        false
    end
  end

  def alnasl_up?, do: port_up?(@alnasl_port)

  # ----------------------------------------------------------------------------- page heartbeat --
  # The menu pages ping every few seconds with the page they show. The kiosk watchdog reads PING_FILE (a
  # file, so it survives a restart of this server) and never restarts the browser while a page is open;
  # and when the browser does restart, "/" sends it back to the page it was on.

  def page_ping(page, first \\ false) do
    now = Sys.now()
    # empty = "not on a menu page" (e.g. the browser went to Alnasl)
    page =
      if is_binary(page) and Regex.match?(~r/\A\/[A-Za-z0-9\/_\-]{0,60}(\?[A-Za-z0-9=&_\-]{0,80})?\z/, page),
        do: page,
        else: ""

    {t, prev} = State.get(:last_page, {0.0, ""})

    if first do
      ago = if t != 0.0, do: trunc(now - t), else: -1
      Py.log("page loaded: #{or_dash(page)} (previous page #{or_dash(prev)}, #{ago} s ago)")
    end

    State.put(:last_page, {now, page})

    try do
      Sys.write_atomic(@ping_file, "#{trunc(now)}\t#{page}\n")
    rescue
      _ in [File.Error, File.RenameError] -> :ok
    end
  end

  defp or_dash(""), do: "-"
  defp or_dash(s), do: s

  @doc "{age in seconds, page} of the last ping, `{nil, \"\"}` when there is none; survives a restart of this server."
  def read_ping do
    case State.get(:last_page, {0.0, ""}) do
      {t, page} when t != 0.0 ->
        {Sys.now() - t, page}

      _ ->
        {ts, page} =
          case String.split(String.trim(Sys.read(@ping_file)), "\t", parts: 2) do
            [ts, page] -> {ts, page}
            [ts] -> {ts, ""}
          end

        case Py.float(ts) do
          nil -> {nil, ""}
          t -> {Sys.now() - t, page}
        end
    end
  end

  @doc "Where a freshly started browser should go instead of the default."
  def resume_page do
    {age, page} = read_ping()

    if age == nil or age > @resume_seconds or not String.starts_with?(page, "/") do
      nil
    else
      base = page |> String.split("?") |> hd() |> String.trim_trailing("/")

      cond do
        base not in @menu_pages and not String.starts_with?(base, "/settings/") -> nil
        base == "/setup" and setup_done?() -> nil
        true -> page
      end
    end
  end

  def kiosk_busy do
    {age, page} = read_ping()
    %{"busy" => age != nil and age < @busy_seconds, "page" => page, "age" => if(age == nil, do: nil, else: trunc(age))}
  end

  def ping_text do
    case read_ping() do
      {nil, _} -> "never"
      {age, page} -> "#{if page == "", do: "(not on a menu page)", else: page}, #{trunc(age)} s ago"
    end
  end

  # --------------------------------------------------------------------------------- keyboard --

  defp keymap_exists?(name) do
    {_rc, out} =
      Sys.run(["find", "/usr/share/keymaps", "/usr/lib/kbd/keymaps", "/lib/kbd/keymaps", "-name", name <> ".map*"],
        timeout: 15
      )

    String.trim(out) != ""
  end

  defp conf_kv(text) do
    for line <- Diag.splitlines(text),
        [_, k, v] <- [Regex.run(~r/^(\w+)="?([^"]*)"?$/u, String.trim(line))],
        into: %{},
        do: {k, v}
  end

  def get_keyboard, do: conf_kv(Sys.read(@kbd_conf))

  def set_keyboard(layout_id) do
    {lid, _label, xl, xv, cmaps} =
      Enum.find(@layouts, &(elem(&1, 0) == layout_id)) || raise(ArgumentError, "unknown keyboard layout")

    cmap = Enum.find(cmaps, "", &keymap_exists?/1)
    Sys.write_atomic(@kbd_conf, ~s(KBD_ID="#{lid}"\nKBD_LAYOUT="#{xl}"\nKBD_VARIANT="#{xv}"\nKBD_CONSOLE="#{cmap}"\n))

    if cmap != "" do
      Sys.write_atomic("/etc/vconsole.conf", "KEYMAP=#{cmap}\n")
      Sys.run(["loadkeys", cmap])
    end

    %{"console_keymap" => cmap}
  end

  # --------------------------------------------------------------------------------- services --

  # v6: no remote login of any kind. Nobody logs in to this box from elsewhere.
  def services_status, do: %{"alnasl" => unit_state("alnasl.service"), "kiosk" => unit_state("alnasl-kiosk.service")}

  defp enable(units, true) do
    sysctl(["enable" | units])
    sysctl(["start", "--no-block" | units])
  end

  defp enable(units, false) do
    sysctl(["disable" | units])
    sysctl(["stop", "--no-block" | units])
  end

  def set_services(req) do
    if Map.has_key?(req, "alnasl"), do: enable(["alnasl.service", "alnasl-update.path"], Py.truthy?(req["alnasl"]))

    # v6: no remote shell and no VPN switches here. The image has neither, and this page will not be the
    # thing that brings one back.
    if Map.has_key?(req, "kiosk") do
      # Enable now; the stop (which removes the screen the user is looking at) waits until the reply has
      # been delivered.
      if Py.truthy?(req["kiosk"]) do
        enable(["alnasl-kiosk.service"], true)
      else
        sysctl(["disable", "alnasl-kiosk.service"])
        Py.later(2.0, fn -> sysctl(["stop", "--no-block", "alnasl-kiosk.service"]) end)
      end
    end

    services_status()
  end

  # --------------------------------------------------------------------------- kiosk / system --

  def get_kiosk_conf, do: Map.merge(%{"KIOSK_SCALE" => "100", "KIOSK_RES" => "auto"}, conf_kv(Sys.read(@kiosk_conf)))

  def set_scale(scale) do
    scale = Py.int!(scale)
    if scale not in [75, 100, 125, 150, 200, 250], do: raise(ArgumentError, "Unsupported scale.")
    set_kiosk_conf(%{"KIOSK_SCALE" => Integer.to_string(scale)})
    %{"ok" => true}
  end

  def set_kiosk_conf(kv) do
    d = Map.merge(get_kiosk_conf(), kv)
    Sys.write_atomic(@kiosk_conf, d |> Enum.sort() |> Enum.map_join(fn {k, v} -> ~s(#{k}="#{v}"\n) end))
  end

  def restart_kiosk do
    if unit_state("alnasl-kiosk.service")["enabled"],
      do: Py.later(1.5, fn -> sysctl(["restart", "--no-block", "alnasl-kiosk.service"]) end)

    :ok
  end

  def hostname, do: :inet.gethostname() |> elem(1) |> to_string()

  # shutil.disk_usage("/"): stat -f, the block size times the blocks (total) and the blocks free to users
  defp disk_usage do
    with {0, out} <- Sys.run(["stat", "-f", "-c", "%S %b %a", "/"]),
         [s, b, a] <- String.split(out),
         {s, ""} <- Integer.parse(s),
         {b, ""} <- Integer.parse(b),
         {a, ""} <- Integer.parse(a) do
      {s * b, s * a}
    else
      _ -> {0, 0}
    end
  end

  def sysinfo do
    up = Sys.read("/proc/uptime", "0 0") |> String.split() |> List.first("0") |> Py.float() || 0.0
    mem = for [_, k, v] <- Regex.scan(~r/(\w+):\s+(\d+) kB/, Sys.read("/proc/meminfo")), into: %{}, do: {k, v}
    {disk_total, disk_free} = disk_usage()
    temp = String.trim(Sys.read("/sys/class/thermal/thermal_zone0/temp"))
    cur = if Sys.exists?("/opt/alnasl/current"), do: Sys.realpath(Sys.path("/opt/alnasl/current")), else: ""

    alnasl =
      case Sys.read("/opt/alnasl/current/VERSION") do
        "" -> if cur == "", do: "?", else: Path.basename(cur)
        v -> v
      end

    %{
      "hostname" => hostname(),
      "model" => strip0(Sys.read("/proc/device-tree/model")),
      "serial" => strip0(Sys.read("/proc/device-tree/serial-number")) |> String.slice(-6, 6),
      "kernel" => String.trim(Sys.read("/proc/sys/kernel/osrelease")),
      "os" =>
        case Regex.run(~r/PRETTY_NAME="?([^"\n]+)/, Sys.read("/etc/os-release")) do
          [_, v] -> v
          _ -> "?"
        end,
      "image" => String.trim(Sys.read("/etc/alnasl/image-version", "?")),
      "image_release" => image_release(),
      "alnasl" => String.trim(alnasl),
      "uptime" => trunc(up),
      "mem_total" => String.to_integer(Map.get(mem, "MemTotal", "0")) * 1024,
      "mem_avail" => String.to_integer(Map.get(mem, "MemAvailable", "0")) * 1024,
      "disk_total" => disk_total,
      "disk_free" => disk_free,
      "temp_c" => if(Regex.match?(~r/^\d+$/, temp), do: Py.round(String.to_integer(temp) / 1000, 1), else: nil),
      "display" => if((d = String.trim(Sys.read(@kiosk_state))) == "", do: "unknown", else: d),
      "net" =>
        for(
          i <- ~w(eth0 wlan0),
          Sys.exists?("/sys/class/net/" <> i),
          into: %{},
          do: {i, Net.hall_side(Net.ipv4_info(i))}
        )
    }
  end

  # str.strip("\0\n")
  defp strip0(s), do: Regex.replace(~r/\A[\x00\n]+|[\x00\n]+\z/, s, "")

  @doc "v6 A/B: this slot's train and version, and which slot runs (A or B)."
  def image_release do
    r =
      for [_, k, v] <-
            Regex.scan(~r/^(ALNASL_TRAIN|ALNASL_VERSION)="?([^"\n]*)"?\s*$/m, Sys.read("/etc/alnasl/image-release")),
          into: %{},
          do: {k, v}

    slot =
      case Regex.run(~r/(?:^|\s)alnasl\.slot=([AB])(?:\s|$)/, Sys.read("/proc/cmdline")) do
        [_, s] -> s
        _ -> ""
      end

    %{"train" => Map.get(r, "ALNASL_TRAIN", ""), "version" => Map.get(r, "ALNASL_VERSION", ""), "slot" => slot}
  end

  @doc "The report's header, in the order it is printed."
  def system_header do
    s = sysinfo()

    [
      {"hostname", s["hostname"]},
      {"model", s["model"]},
      {"serial", s["serial"]},
      {"kernel", s["kernel"]},
      {"os", s["os"]},
      {"image", s["image"]},
      {"alnasl", s["alnasl"]},
      {"uptime", "#{s["uptime"]} s"},
      {"screen", s["display"]},
      # v7: what the box is, chosen and running (the ROLE section has the detail)
      {"role",
       "#{or_text(String.trim(Sys.read(@role_run)), "none this boot")} (chosen: #{or_text(String.trim(Sys.read(@mode_file)), "default")})"}
    ]
  end

  defp or_text("", d), do: d
  defp or_text(s, _), do: s

  def diag_info, do: Diag.collect(Wifi.summary(), Wifi.last_scan(), %{"ping" => ping_text()})

  def diag_save do
    text = Diag.report_text(diag_info(), Diag.journals(), system_header())

    case Diag.save_report(text) do
      {:ok, name} ->
        Py.log("diagnostics saved to #{name}")

        %{
          "ok" => true,
          "file" => name,
          "where" => "the boot partition of the SD card (the small drive that shows up on a PC)"
        }

      {:error, msg} ->
        raise ArgumentError, "Could not write to the SD card: " <> msg
    end
  end

  # ------------------------------------------------------------------------------------- roles --

  def roles, do: @roles

  def canon_role(word) do
    w = if is_binary(word), do: word |> String.trim() |> String.downcase(), else: ""
    w = Map.get(@aliases, w, w)
    if w in @roles, do: w, else: nil
  end

  @doc "The box's role as chosen. Nothing set (or nonsense) means alnasl."
  def get_mode, do: canon_role(Sys.read(@mode_file)) || "alnasl"

  def running_role, do: canon_role(Sys.read(@role_run)) || get_mode()

  @doc """
  GET /api/mode. "mode" stays v6's word for the two v6 roles (Arkab's page compares it with
  master/slave); "role" is the v7 word.
  """
  def mode_status do
    role = get_mode()
    run = running_role()

    %{
      "mode" => Map.get(@legacy, role, role),
      "role" => role,
      "roles" => @roles,
      "set" => canon_role(Sys.read(@mode_file)) != nil,
      "running" => Map.get(@legacy, run, run),
      "running_role" => run
    }
  end

  def set_mode(mode) do
    role = canon_role(mode) || raise(ArgumentError, "bad_mode")
    Sys.write_atomic(@mode_file, role <> "\n", 0o644)
    role
  end

  @doc """
  Settings > Change what this box is, and Arkab's page. The role is only a file that alnasl-mode reads
  at boot, so the switch is that file and a restart (the boot screen shows it). Nothing is deleted:
  every app keeps its data, switching back loses nothing.
  """
  def switch_mode(mode, confirm) do
    if confirm != "SWITCH", do: raise(ArgumentError, "Not confirmed.")
    role = canon_role(mode) || raise(ArgumentError, "bad_mode")

    if role == running_role() and role == get_mode() do
      %{"ok" => true, "mode" => Map.get(@legacy, role, role), "role" => role, "same" => true}
    else
      # the diagnostics read this line
      Py.log("role switch: #{get_mode()} -> #{role} (running #{running_role()}); restarting")
      set_mode(role)
      power("reboot")
      %{"ok" => true, "mode" => Map.get(@legacy, role, role), "role" => role, "same" => false}
    end
  end

  def role_up?(role \\ nil), do: port_up?(@role_port[role || running_role()])

  @doc "The role's own app is switched on (Settings > Services can switch Alnasl off)."
  def role_wanted?(role \\ nil), do: unit_state("#{role || running_role()}.service")["enabled"]

  # ------------------------------------------------------------------------------------- sound --
  # Settings > Sound, on a nunki box: which output the announcer speaks through, and how loud.
  # alnasl-sound writes /etc/asound.conf from sound.conf and sets the volume.
  @sound_conf @state_dir <> "/sound.conf"
  @sound "/usr/local/sbin/alnasl-sound"
  @sound_outputs ~w(hdmi hdmi2 jack)

  def sound_status do
    kv = for [_, k, v] <- Regex.scan(~r/^([A-Z]+)=([a-z0-9]*)/m, Sys.read(@sound_conf)), into: %{}, do: {k, v}
    {rc, out} = Sys.run([@sound, "--cards"], timeout: 20)
    have = if rc == 0, do: Enum.filter(String.split(out), &(&1 in @sound_outputs)), else: []
    output = if kv["OUTPUT"] in @sound_outputs, do: kv["OUTPUT"], else: "hdmi"
    v = Map.get(kv, "VOLUME", "")
    vol = if Regex.match?(~r/^\d+$/, v) and String.to_integer(v) <= 100, do: String.to_integer(v), else: 80
    %{"outputs" => have, "output" => output, "volume" => vol}
  end

  def set_sound(b) do
    cur = sound_status()
    out = Map.get(b, "output", cur["output"])
    if out not in @sound_outputs, do: raise(ArgumentError, "bad_output")

    vol =
      case Py.int(Map.get(b, "volume", cur["volume"])) do
        {:ok, v} when v in 0..100 -> v
        _ -> raise ArgumentError, "bad_volume"
      end

    Sys.write_atomic(@sound_conf, "OUTPUT=#{out}\nVOLUME=#{vol}\n", 0o644)
    Sys.run([@sound], timeout: 30)
    sound_status()
  end

  def sound_test do
    nl = lang() == "nl"
    line = if nl, do: "Dit is de omroeper. Een, twee, drie.", else: "This is the announcer. One, two, three."
    Py.later(0.2, fn -> Sys.run([@sound, "--test", if(nl, do: "nl", else: "en"), line], timeout: 30) end)
    %{"ok" => true}
  end

  # ----------------------------------------------------------------------------------- console --
  # The kiosk holds tty1. Ctrl+Alt+F2/F3 should reach the consoles (getty@tty2, getty@tty3 are enabled);
  # these two actions do the same without a keyboard shortcut, which is also the test of whether the VT
  # switch itself works.

  def console_show do
    Py.later(0.8, fn -> Sys.run(["chvt", "2"]) end)
    %{"ok" => true}
  end

  defp stop_screen do
    sysctl(["stop", "alnasl-kiosk.service"])
    Py.nap(1.5)

    note =
      "\r\n\r\nThe Alnasl screen is stopped (until the next boot).\r\n" <>
        "To bring it back: run  alnasl-screen start  (or restart the box).\r\n\r\n"

    for tty <- ~w(/dev/tty1 /dev/tty2), do: File.write(Sys.path(tty), note)
    Sys.run(["chvt", "1"])
    Py.log("the screen (kiosk) was stopped from the menu; it starts again at the next boot")
  end

  def screen_stop do
    Py.later(1.0, &stop_screen/0)
    %{"ok" => true}
  end

  # ------------------------------------------------------------------------------- boot screen --

  defp messages do
    case Json.decode(Sys.read(@splash <> "/messages.json", "")) do
      {:ok, m} -> {:ok, m}
      _ -> :error
    end
  end

  def screen_states do
    case messages() do
      {:ok, %{} = m} -> Map.get(m, "states", %{})
      _ -> %{}
    end
  end

  @doc "The state the boot screen shows (the browser's /screen page and the framebuffer)."
  def set_screen(key) do
    if Map.has_key?(screen_states(), key), do: Sys.write_atomic(@screen_state, key <> "\n")
  end

  @doc "Where the value line and the bar of the update states go (1080-line units), and the glyphs."
  def screen_geom do
    case messages() do
      {:ok, %{} = m} ->
        g = Map.get(m, "geometry", %{})
        gl = (m["glyphs"] || %{})["1080"] || %{}

        %{
          "adv" => Map.get(gl, "advance", %{}),
          "names" => Map.get(gl, "names", %{}),
          "height" => Map.get(gl, "height", 42),
          "sub_y" => Map.get(g, "sub_y", 282),
          "dots_y" => Map.get(g, "dots_y", 346),
          "bar_w" => Map.get(g, "bar_w", 360),
          "bar_h" => Map.get(g, "bar_h", 6),
          "bar_steps_y" => Map.get(g, "bar_steps_y", 380),
          # the page only asks whether a state is in it, so the order does not matter
          "with_steps" => for({k, v} <- m["states"] || %{}, Py.truthy?(v["steps"]) and Py.truthy?(v["bar"]), do: k)
        }

      _ ->
        nil
    end
  end

  @doc "What screen.html needs to lay the log out exactly as alnasl-splash does."
  def bootlog_view do
    case messages() do
      {:ok, %{"mono" => mono, "logview" => lv} = m} ->
        %{"mono" => mono, "logview" => lv, "steps" => for({k, v} <- m["states"] || %{}, Py.truthy?(v["steps"]), do: k)}

      _ ->
        nil
    end
  end

  # v7: the boot log for the browser's /boot page (screen.html), after X has taken the screen from the
  # framebuffer painter. Same source, same allow-list, same redaction, same order (AlnaslSetup.Bootlog),
  # so the page carries on with the lines the painter last showed, in the same places. Loopback only,
  # like all of this server. The reader lives in AlnaslSetup.Server.State.
  def bootlog_get(q) do
    State.bootlog_start()

    after_n =
      case Py.int(Py.qs_first(q, "after", "0")) do
        {:ok, n} -> n
        _ -> 0
      end

    {text, t} = State.get(:bootlog_status, {"", -1.0e9})

    text =
      if Py.monotonic() - t > 1.0 do
        text = Py.mod(:bootlog).status(lang())["text"]
        State.put(:bootlog_status, {text, Py.monotonic()})
        text
      else
        text
      end

    snap = State.bootlog_snapshot(after_n)

    out = %{
      "seq" => snap.seq,
      "ready" => snap.ready,
      "status" => text,
      "lines" =>
        for({n, tag, col, err, msg} <- snap.lines, do: %{"n" => n, "t" => tag, "c" => col, "e" => err, "m" => msg})
    }

    if after_n == 0, do: Map.put(out, "view", bootlog_view()), else: out
  end

  def bootscreen do
    st = String.trim(Sys.read(@screen_state))
    st = if Map.has_key?(screen_states(), st), do: st, else: ""

    out = %{
      "state" => st,
      "lang" => lang(),
      # v7: "alnasl" here is the role's own app (the page the screen goes to), whatever the role.
      "alnasl_wanted" => setup_done?() and role_wanted?(),
      "alnasl_up" => role_up?(),
      "role" => running_role()
    }

    val = String.trim(Sys.read(@screen_value))
    prog = String.trim(Sys.read(@screen_progress))

    if st != "" and (val != "" or prog != "") do
      Map.merge(out, %{
        "value" => if(Regex.match?(~r/\A[0-9v.%]{1,12}\z/, val), do: val, else: ""),
        "progress" =>
          if(Regex.match?(~r/\A\d+\z/, prog) and String.to_integer(prog) <= 100, do: String.to_integer(prog), else: nil),
        "geom" => screen_geom()
      })
    else
      out
    end
  end

  # ---------------------------------------------------------------------------- system updates --
  # v6 A/B: the whole system image (alnasl-system-update does the work, as root, outside this server).
  # This server only reads its status and leaves it a request file; the unit picks that up. Never a train
  # change without the word UPGRADE from the page that asked (the menu's confirmation, or Arkab's).
  @sys_request "/var/lib/alnasl-os-update/system/request"
  @painted @kiosk_run <> "/painted"

  @doc "The kiosk's browser has loaded a page from here: the health check of a new slot waits for this."
  def mark_painted do
    if not Sys.exists?(@painted) do
      try do
        File.mkdir_p!(Sys.path(@kiosk_run))
        File.write!(Sys.path(@painted), "")
      rescue
        _ in File.Error -> :ok
      end
    end

    :ok
  end

  def system_status do
    case Py.mod(:system_update).status() do
      %{} = s -> s
      _ -> %{"ab" => false, "error" => "unavailable"}
    end
  rescue
    _ -> %{"ab" => false, "error" => "unavailable"}
  catch
    _, _ -> %{"ab" => false, "error" => "unavailable"}
  end

  defp train_no(t) do
    case Regex.run(~r/\Av([0-9]{1,3})\z/, Py.str_or_empty(t)) do
      [_, n] -> String.to_integer(n)
      _ -> raise ArgumentError, "bad_train"
    end
  end

  def system_request(action, train \\ nil, by \\ "menu") do
    s = system_status()
    if not Py.truthy?(s["ab"]), do: raise(ArgumentError, "not_ab")
    if not Py.truthy?(s["updates_on"]), do: raise(ArgumentError, "updates_off")
    if Py.truthy?(s["busy"]) or Py.truthy?(s["trial"]), do: raise(ArgumentError, "busy")
    r = %{"action" => action, "by" => if(by in ["menu", "arkab"], do: by, else: "menu")}

    r =
      if action == "upgrade" do
        if train_no(train) <= train_no(s["train"]), do: raise(ArgumentError, "bad_train")
        Map.put(r, "train", train)
      else
        r
      end

    write_private(@sys_request, Json.encode(r) <> "\n", follow: true)
    sysctl(["start", "--no-block", "alnasl-system-update.service"])
    %{"ok" => true}
  end

  def system_check do
    sysctl(["start", "--no-block", "alnasl-system-update-check.service"])
    %{"ok" => true}
  end

  def system_url(url) do
    url = String.trim(url)

    if url != "" do
      u = Py.urlsplit(url)

      if Py.len(url) > 300 or not String.starts_with?(url, "https://") or Regex.match?(~r/[\s\x00-\x1f\x7f]/u, url) or
           Py.truthy?(u.username) or not Py.truthy?(u.hostname),
         do: raise(ArgumentError, "bad_url")
    end

    set_state(update_url: url)
    system_status()
  end

  # ------------------------------------------------------------------------------------- power --

  def power(action) do
    if action not in ["reboot", "poweroff"], do: raise(ArgumentError, "bad action")
    set_screen(if action == "reboot", do: "reboot", else: "shutdown")
    Py.later(1.5, fn -> sysctl([action, "--no-block"]) end)
    %{"ok" => true}
  end

  @doc """
  Erase the box back to new (alnasl-reset). The page has had the operator hold a button; the word is
  checked here too, so nothing but that page's own request can start it.
  """
  def factory_reset(confirm) do
    if confirm != "RESET", do: raise(ArgumentError, "Not confirmed.")
    set_screen("reset-1")
    Py.later(1.0, fn -> sysctl(["start", "--no-block", "alnasl-reset.service"]) end)
    %{"ok" => true}
  end

  @doc "Runs `fun` under the server's lock (every POST, every timer that changes the box)."
  def locked(fun), do: Lock.with_lock(fun)
end
