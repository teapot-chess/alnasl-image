defmodule AlnaslSetup.Server.Remote do
  @moduledoc """
  Remote access, opt-in (v7.5, docs/remote-access.md): the menu's Start / New code / Leave and what it shows in
  between. All the work is `/usr/local/sbin/alnasl-tailscale` (root, outside this server's own code); this module
  only asks it and reads `tailscale status --json` back through it.

  The flow: Start -> the box asks Tailscale for a login link -> the menu shows it as a big QR code (and as text)
  -> the owner scans it with a phone and approves the box in their own Tailscale account -> connected (the
  tailnet address, the MagicDNS name; Tailscale SSH on). There is no auth key anywhere, in the image or here.

  `summarize/2` is the pure part (remote_test.exs): Tailscale's status plus when Start was pressed and when the
  link was first seen -> one of `off`, `starting`, `login`, `no_internet`, `approve`, `connected`, `stopped`.
  """
  alias AlnaslSetup.{Json, QR, Sys}
  alias AlnaslSetup.Server.{Py, State}

  @cli "/usr/local/sbin/alnasl-tailscale"
  @flag "/var/lib/alnasl-tailscale/enabled"
  # A link nobody used for this long may be dead; the page offers a new one (it never stops showing the old one).
  @link_stale 600
  # Start pressed this long ago and still no link: most likely no way out to the internet.
  @no_link 30

  def link_stale, do: @link_stale

  # The home screen asks every few seconds; Tailscale is asked at most this often.
  @addr_ttl 30

  @doc """
  The box's tailnet address for the home screen, `%{"ip", "dns_name"}`, or nil while remote access is off or not
  connected. Cached for #{@addr_ttl} s: the screen polls far more often than the address can change.
  """
  def address do
    if Sys.exists?(@flag) do
      now = Sys.now()

      case State.get(:remote_addr) do
        {t, v} when now - t < @addr_ttl ->
          v

        _ ->
          {_rc, out} = Sys.run([@cli, "status"], timeout: 8)
          st = Json.decode_or_nil(out) || %{}
          v = address_of(summarize(st, %{on: true, now: now, started: nil, link_seen: nil}))
          State.put(:remote_addr, {now, v})
          v
      end
    end
  end

  @doc false
  # The pure part of `address/0`: only a connected box with an address has one to show.
  def address_of(%{"state" => "connected", "ip" => ip} = s) when is_binary(ip) and ip != "",
    do: %{"ip" => ip, "dns_name" => s["dns_name"]}

  def address_of(_), do: nil

  @doc "Remote access is installed in this image (the binaries are where alnasl-tailscale expects them)."
  def available?,
    do: Sys.exists?(@cli) and Sys.exists?("/usr/local/bin/tailscale") and Sys.exists?("/usr/local/sbin/tailscaled")

  @doc """
  The view from `tailscale status --json` (decoded; `%{}` while tailscaled is not running) and
  `%{on, now, started, link_seen}` (seconds; nil when unknown).
  """
  def summarize(st, ctx) do
    st = if is_map(st), do: st, else: %{}
    backend = st["BackendState"]
    url = st["AuthURL"]
    self = if is_map(st["Self"]), do: st["Self"], else: %{}
    since = if ctx.started, do: ctx.now - ctx.started, else: nil

    cond do
      not ctx.on ->
        %{"state" => "off"}

      backend == "Running" ->
        ips = List.wrap(self["TailscaleIPs"])

        %{
          "state" => "connected",
          "ip" => Enum.find(ips, &(is_binary(&1) and not String.contains?(&1, ":"))) || List.first(ips),
          "ip6" => Enum.find(ips, &(is_binary(&1) and String.contains?(&1, ":"))),
          "dns_name" => (self["DNSName"] || "") |> to_string() |> String.trim_trailing("."),
          "tailnet" => get_in(st, ["CurrentTailnet", "Name"]),
          "ssh" => true
        }

      backend == "NeedsMachineAuth" ->
        %{"state" => "approve"}

      is_binary(url) and url != "" ->
        age = if ctx.link_seen, do: ctx.now - ctx.link_seen, else: 0
        %{"state" => "login", "url" => url, "stale" => age >= @link_stale, "age" => trunc(age)}

      backend == "Stopped" ->
        %{"state" => "stopped"}

      # on since an earlier start (a restart of the box), logged out meanwhile: nobody is waiting for a link yet
      backend == "NeedsLogin" and since == nil ->
        %{"state" => "stopped"}

      since != nil and since >= @no_link ->
        %{"state" => "no_internet", "waited" => trunc(since)}

      true ->
        %{"state" => "starting"}
    end
  end

  @doc "GET /api/remote: what the menu shows now (with the QR code's rows for a login link)."
  def status do
    on = Sys.exists?(@flag)
    now = Sys.now()

    st =
      if on do
        {_rc, out} = Sys.run([@cli, "status"], timeout: 8)
        Json.decode_or_nil(out) || %{}
      else
        %{}
      end

    url = st["AuthURL"]

    link_seen =
      case {url, State.get(:remote_link)} do
        {u, {u, t}} when is_binary(u) and u != "" ->
          t

        {u, _} when is_binary(u) and u != "" ->
          State.put(:remote_link, {u, now})
          now

        _ ->
          nil
      end

    v = summarize(st, %{on: on, now: now, started: State.get(:remote_started), link_seen: link_seen})

    v =
      if v["state"] == "login",
        do:
          Map.put(v, "rows", url |> QR.encode() |> Enum.map(fn r -> Enum.map_join(r, &if(&1, do: "1", else: "0")) end)),
        else: v

    Map.merge(v, %{"available" => available?(), "hostname" => :inet.gethostname() |> elem(1) |> to_string()})
  end

  defp cli(arg, timeout) do
    {rc, out} = Sys.run([@cli, arg], timeout: timeout, stderr: :merge)
    Py.log("remote access: #{arg} -> #{rc}")
    {rc, out}
  end

  @reasons %{3 => "not_installed", 4 => "no_tun", 5 => "no_daemon", 6 => "off"}

  @doc "POST /api/remote/start"
  def start do
    if not available?(), do: raise(ArgumentError, "not_installed")
    State.put(:remote_started, Sys.now())
    State.put(:remote_link, nil)

    case cli("start", 40) do
      {0, _} -> %{"ok" => true}
      {rc, _} -> %{"ok" => false, "error" => Map.get(@reasons, rc, "failed")}
    end
  end

  @doc "POST /api/remote/new-code: a fresh login link."
  def new_code do
    State.put(:remote_started, Sys.now())
    State.put(:remote_link, nil)

    case cli("relogin", 30) do
      {0, _} -> %{"ok" => true}
      {rc, _} -> %{"ok" => false, "error" => Map.get(@reasons, rc, "failed")}
    end
  end

  @doc "POST /api/remote/leave {confirm: \"LEAVE\"}: logged out, stopped, state wiped."
  def leave(confirm) do
    if confirm != "LEAVE", do: raise(ArgumentError, "Not confirmed.")
    State.put(:remote_started, nil)
    State.put(:remote_link, nil)
    {rc, _} = cli("leave", 60)
    %{"ok" => rc == 0}
  end
end
