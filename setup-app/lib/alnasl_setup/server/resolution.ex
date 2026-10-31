defmodule AlnaslSetup.Server.Resolution do
  @moduledoc """
  The screen resolution (was the resolution part of server.py).

  The modes the connected screen really offers come from the kernel (DRM connector "modes" file; the
  first line is the screen's preferred mode). A pick is applied LIVE inside the kiosk container
  (kiosk-res: wlr-randr under cage, xrandr under X) and saved; kiosk.sh applies it again at every start.
  Like the network settings it must be confirmed: after the confirm window the previous setting comes
  back by itself, from this server, so a mode that gives a black screen undoes itself.
  """
  alias AlnaslSetup.{Lock, Sys}
  alias AlnaslSetup.Server.{Box, Py, State}

  # extra seconds when the screen has to restart to switch (it takes a while to come back)
  @restart_extra 25
  @res_re ~r/\A[0-9]{3,5}x[0-9]{3,5}\z/
  @idle %{timer: nil, token: nil, prev: nil, deadline: 0.0}

  defp confirm_seconds, do: Py.env(:res_confirm_seconds, 20)
  defp pending, do: State.get(:res_pending, @idle)
  defp put_pending(p), do: State.put(:res_pending, p)

  @doc "{connector name such as HDMI-A-1, [progressive modes WxH, preferred first]} of the first connected screen."
  def drm_connector do
    # (a Windows temporary root has backslashes, which a wildcard takes for escapes)
    root = String.replace(Sys.path("/sys/class/drm"), "\\", "/")

    (root <> "/card*-*")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.sort()
    |> Enum.find_value({nil, []}, fn name ->
      d = "/sys/class/drm/" <> name

      if String.trim(Sys.read(d <> "/status")) == "connected" do
        modes =
          (d <> "/modes")
          |> Sys.read()
          |> AlnaslSetup.Diag.splitlines()
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&Regex.match?(@res_re, &1))
          |> Enum.uniq()

        {Regex.replace(~r/^card[0-9]+-/, name, ""), modes}
      end
    end)
  end

  def status do
    {conn, modes} = drm_connector()
    cur = Map.get(Box.get_kiosk_conf(), "KIOSK_RES", "auto")
    p = pending()
    pend = p.timer != nil

    %{
      "connector" => conn,
      "modes" => modes,
      "preferred" => List.first(modes),
      "setting" => if(cur == "auto" or cur in modes, do: cur, else: "auto"),
      "pending" => pend,
      "seconds_left" => if(pend, do: max(0, trunc(p.deadline - Sys.now())), else: 0),
      "confirm_seconds" => confirm_seconds(),
      "kiosk_running" => Box.unit_state("alnasl-kiosk.service")["active"]
    }
  end

  @doc "Apply a mode inside the running kiosk container. {ok, message}"
  def live(conn, mode) do
    if not Box.unit_state("alnasl-kiosk.service")["active"] do
      {false, "the screen is not running"}
    else
      {rc, out} =
        Sys.run(
          ["docker", "exec", "-e", "XDG_RUNTIME_DIR=/run/user/0", "-e", "WAYLAND_DISPLAY=wayland-0", "-e", "DISPLAY=:0"] ++
            ["alnasl-kiosk", "/usr/local/bin/kiosk-res", "apply", conn || "-", mode],
          timeout: 25
        )

      out = String.trim(out)
      {rc == 0, if(String.length(out) > 400, do: String.slice(out, -400, 400), else: out)}
    end
  end

  # The revert itself; the caller holds the lock.
  defp revert_now do
    prev = pending().prev
    put_pending(@idle)

    if prev != nil do
      {conn, _modes} = drm_connector()
      Box.set_kiosk_conf(%{"KIOSK_RES" => prev})
      {ok, msg} = live(conn, prev)
      Py.log("resolution was not confirmed; back to #{prev} (#{if ok, do: "ok", else: msg})")
      # kiosk.sh applies the saved value at its start
      if not ok, do: Box.restart_kiosk()
    end

    :ok
  end

  # The timer's end: only for the change it was started for (a confirm or a newer change wins).
  defp timer_revert(token) do
    Lock.with_lock(fn -> if pending().token == token, do: revert_now() end)
  end

  def set(mode) do
    {conn, modes} = drm_connector()
    if mode != "auto" and mode not in modes, do: raise(ArgumentError, "The screen does not offer that resolution.")
    p = pending()

    # a second change before the first was confirmed: keep the ORIGINAL to go back to
    prev =
      if p.timer != nil do
        State.cancel(p.timer)
        p.prev
      else
        Map.get(Box.get_kiosk_conf(), "KIOSK_RES", "auto")
      end

    {ok, msg} = live(conn, mode)
    running = Box.unit_state("alnasl-kiosk.service")["active"]
    # X on the fbdev driver has one mode only, so xrandr cannot switch it. The kiosk then has to restart:
    # kiosk.sh starts X with the KMS (modesetting) driver whenever a resolution is chosen.
    kstate = Sys.read(Box.kiosk_state_file())

    restart_needed =
      not ok and running and String.contains?(kstate, "path=x") and not String.contains?(kstate, "driver=modesetting")

    if not ok and running and not restart_needed do
      put_pending(@idle)
      raise ArgumentError, "The screen would not switch: " <> if(msg == "", do: "no answer", else: msg)
    end

    Box.set_kiosk_conf(%{"KIOSK_RES" => mode})

    if not running do
      # nothing to confirm on a screen that is not there (an earlier change, if any, ends here too)
      put_pending(@idle)
      %{"ok" => true, "live" => false, "pending" => false, "confirm_seconds" => 0}
    else
      wait = confirm_seconds() + 2 + if(restart_needed, do: @restart_extra, else: 0)
      token = make_ref()
      timer = State.timer(wait, fn -> timer_revert(token) end)
      put_pending(%{timer: timer, token: token, prev: prev, deadline: Sys.now() + wait})

      if restart_needed do
        Box.restart_kiosk()
        Py.log("resolution #{mode} saved; the screen restarts to use it (#{msg}); waiting for confirmation")
      else
        Py.log("resolution #{mode} applied (#{msg}); waiting for confirmation")
      end

      %{
        "ok" => true,
        "live" => not restart_needed,
        "restart" => restart_needed,
        "pending" => true,
        "confirm_seconds" => wait - 2
      }
    end
  end

  def confirm do
    State.cancel(pending().timer)
    put_pending(@idle)
    %{"ok" => true}
  end

  @doc "The user pressed Undo: same as the timer running out, right now."
  def cancel do
    State.cancel(pending().timer)
    revert_now()
    %{"ok" => true}
  end
end
