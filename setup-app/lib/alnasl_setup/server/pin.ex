defmodule AlnaslSetup.Server.Pin do
  @moduledoc """
  The box's access PIN on the setup pages (Settings > PIN, the compact screen, the hotspot's setup page).

  Every role's app has a PIN, always; the box shows it and can change it. The work is /usr/local/sbin/alnasl-pin's
  (one implementation of the rules, the hand-over and the SD card's file): this module asks it through
  `/var/lib/alnasl-setup/pin-wanted` (0600, root's), runs `alnasl-pin --apply`, and reads back what it wrote.

  What the PIN is now: the role's app's own `access-pin` when it is there and good, else the box's copy
  (`/var/lib/alnasl-setup/pin`, role then PIN). Only ever sent to the box's own screen (the setup server
  listens on 127.0.0.1); the hotspot's page can set one and is never told it. Never logged.
  """
  alias AlnaslSetup.Sys
  alias AlnaslSetup.Server.Box

  @script "/usr/local/sbin/alnasl-pin"
  @copy "/var/lib/alnasl-setup/pin"
  @wanted "/var/lib/alnasl-setup/pin-wanted"

  def copy_file, do: @copy

  @doc "The PIN rules of every app and of alnasl-pin: the error code, or nil when it is good."
  def why_bad(pin) when is_binary(pin) do
    cond do
      not String.valid?(pin) -> "pin_control"
      String.length(pin) < 6 -> "pin_short"
      String.length(pin) > 64 -> "pin_long"
      String.trim(pin) != pin -> "pin_edges"
      Enum.any?(String.to_charlist(pin), &(&1 < 32 or &1 in 127..159)) -> "pin_control"
      true -> nil
    end
  end

  def why_bad(_), do: "pin_short"

  @doc "The PIN now: `%{\"pin\" => text | nil, \"role\" => role}`."
  def current do
    role = Box.running_role()
    app = first_line("/var/lib/#{role}/access-pin")

    pin =
      cond do
        app != nil and why_bad(app) == nil -> app
        true -> copy_pin()
      end

    %{"pin" => pin, "role" => role}
  end

  @doc "The box's copy, for the boot log's redaction too; nil without one."
  def copy_pin do
    case String.split(Sys.read(@copy), "\n") do
      [_role, pin | _] when pin != "" -> pin
      _ -> nil
    end
  end

  defp first_line(p) do
    if Sys.regular?(p) and not symlink?(p) do
      case Sys.read(p) |> String.split("\n") |> hd() |> String.trim_trailing("\r") do
        "" -> nil
        l -> l
      end
    end
  end

  defp symlink?(p), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(Sys.path(p)))

  @doc """
  POST /api/pin: `{"pin": "..."}` sets one, `{"new": true}` makes a random one. Answers `%{"ok", "pin"}`;
  `reveal: false` (the hotspot's page) leaves the PIN out of the answer.
  """
  def change(b, reveal \\ true) do
    request =
      if b["new"] == true do
        "new\n"
      else
        pin = b["pin"]
        if (err = why_bad(pin)) != nil, do: raise(ArgumentError, err)
        "set\n#{pin}\n"
      end

    Box.write_private(@wanted, request)

    case Sys.run([@script, "--apply"], timeout: 30) do
      {0, _} -> :ok
      {3, _} -> raise(ArgumentError, "pin_short")
      {4, _} -> raise(ArgumentError, "app_missing")
      _ -> raise(ArgumentError, "pin_failed")
    end

    if reveal, do: %{"ok" => true, "pin" => copy_pin()}, else: %{"ok" => true}
  end
end
