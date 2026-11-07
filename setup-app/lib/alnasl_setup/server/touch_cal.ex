defmodule AlnaslSetup.Server.TouchCal do
  @moduledoc """
  Settings > Touch screen, the part with a clock on it (v7.5).

  The page taps five crosses and posts them; the box fits them and uses the result AT ONCE (SmallScreen.try_calibration:
  the udev rule in /run and the running X told through xinput), without saving it. The person then tries the stylus
  on the page's test dot and presses Keep (saved on the data partition, kept across reboots) or Undo. A calibration
  that is wrong enough to make the Keep button unreachable undoes itself: the timer here puts the saved one back
  after `touch_try_seconds` (default 20, plus two for the answer to arrive), the same way a resolution change does.
  """
  alias AlnaslSetup.{Lock, SmallScreen}
  alias AlnaslSetup.Server.{Box, Py, State}

  @idle %{timer: nil, token: nil, c: nil}

  defp try_seconds, do: Py.env(:touch_try_seconds, 20)
  defp pending, do: State.get(:touch_pending, @idle)
  defp put_pending(p), do: State.put(:touch_pending, p)

  @doc "Fit and use the taps for `try_seconds`. %{ok, error_pct, live, seconds}; `live` false means the screen must restart."
  def try_it(samples) do
    State.cancel(pending().timer)
    {c, res, live} = SmallScreen.try_calibration(samples)
    secs = try_seconds()
    token = make_ref()
    timer = State.timer(secs + 2, fn -> timer_revert(token) end)
    put_pending(%{timer: timer, token: token, c: c})

    %{"ok" => true, "live" => live, "error_pct" => Float.round(res * 100, 1), "seconds" => secs}
  end

  @doc "Keep: the tried calibration is saved."
  def keep do
    p = pending()
    if p.c == nil, do: raise(ArgumentError, "There is nothing to keep (the time ran out, so it went back).")
    State.cancel(p.timer)
    put_pending(@idle)
    SmallScreen.keep_calibration(p.c)
    %{"ok" => true}
  end

  @doc "Undo: the saved calibration comes back. %{ok, live}"
  def undo do
    p = pending()
    State.cancel(p.timer)
    put_pending(@idle)
    %{"ok" => true, "live" => if(p.c == nil, do: true, else: SmallScreen.revert_calibration())}
  end

  # The timer's end: only for the trial it was started for.
  defp timer_revert(token) do
    Lock.with_lock(fn ->
      p = pending()

      if p.token == token and p.c != nil do
        put_pending(@idle)
        live = SmallScreen.revert_calibration()
        Py.log("touch calibration was not kept; back to the saved one (live: #{live})")
        if not live, do: Box.restart_kiosk()
      end
    end)
  end
end
