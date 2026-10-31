defmodule AlnaslSetup.BootlogTest do
  # What the v7 boot screen may show of the box's log (port of scripts/test-bootlog.py).
  #
  # The screen stands in a public hall: a secret that reaches it is in somebody's photo. So every kind of
  # secret the box knows of is tried here, and so are the lines that must stay readable (a failed unit is
  # never hidden).
  use ExUnit.Case, async: false
  alias AlnaslSetup.Bootlog, as: B
  alias AlnaslSetup.Bootlog.Follower
  alias AlnaslSetup.Test.Box

  defp shown(msg), do: B.ascii_line(B.redact(msg))

  @secrets [
    {~s(psk="hunter2hunter2" key_mgmt=WPA-PSK), "hunter2hunter2"},
    {"wlan0: passphrase=CorrectHorse ssid=Hall", "CorrectHorse"},
    {"wpa_passphrase Hall S3cretWifi!", "S3cretWifi"},
    {"sae_password=zxcvbnm123", "zxcvbnm123"},
    {"psk=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "0123456789abcdef"},
    {"password: letmein99", "letmein99"},
    {~s({"token": "tok_live_abc"}), "tok_live_abc"},
    {"api_key=k-1234-5678", "k-1234-5678"},
    {"Authorization: Bearer abc.def.ghi", "abc.def.ghi"},
    {"sent with bearer qwertyuiop12", "qwertyuiop12"},
    {"Set-Cookie: _alnasl_key=SFMyNTY.g3QAAAAB; path=/", "SFMyNTY"},
    {"cookie=abcdef; secret_key_base=xyz789", "xyz789"},
    {"fetch https://admin:pa55word@updates.example.org/index.json", "pa55word"},
    {"GET https://pairings.cloud/join?token=Zx81kQ", "Zx81kQ"},
    {"GET /api/join?t=Zx81kQ HTTP/1.1", "Zx81kQ"},
    {"join link https://pairings.cloud/j/AbcDEF12345xyzQRs", "AbcDEF12345xyzQRs"},
    {"signed in, session=9f8e7d6c5b4a", "9f8e7d6c5b4a"},
    {"jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig", "eyJhbGciOiJIUzI1NiJ9"},
    {"support: help code 482913, valid until 18:00", "482913"},
    {"your code is 482 913", "482 913"},
    {"code=482-913", "482-913"},
    {"machine-id 5c1f0b2e9a7d4c3b8e6f1a2b3c4d5e6f", "5c1f0b2e9a7d4c3b"},
    {"pin: 4821", "4821"},
    {"otp=917355", "917355"},
    {"mailing jorian@example.org", "jorian@"},
    {"x-api-key: AKIA1234ABCD5678EFGH", "AKIA1234ABCD5678EFGH"},
    {"credentials=user:pw", "user:pw"},
    {"private_key=/etc/x.pem passwd=aa", "passwd=aa"}
  ]

  @keep [
    {"Main process exited, code=exited, status=1/FAILURE", "code=exited, status=1/FAILURE"},
    {"Failed to start nunki.service - Nunki.", "Failed to start nunki.service"},
    {"Started polis.service - Polis.", "Started polis.service"},
    {"wlan0: link becomes ready", "wlan0: link becomes ready"},
    {"eth0: Link is Up - 1Gbps/Full", "Link is Up - 1Gbps/Full"},
    {"Reached target Network.", "Reached target Network."},
    {"vc4-drm gpu: [drm] fb0: vc4drmfb frame buffer device", "fb0: vc4drmfb"},
    {"Running on http://localhost:4062 (port 4062)", "localhost:4062"},
    {"Listening on port 4040", "4040"},
    {"brcmfmac: Firmware: BCM4345/6 wl0: Jan  4 2021", "BCM4345/6"},
    {"Memory: 3870160K/4050944K available", "3870160K"}
  ]

  describe "redaction" do
    for {{msg, secret}, i} <- Enum.with_index(@secrets) do
      test "secret #{i} never reaches the screen" do
        {msg, secret} = {unquote(msg), unquote(secret)}
        out = shown(msg)
        refute String.contains?(out, secret), "#{msg} -> #{out}"
      end
    end

    for {{msg, part}, i} <- Enum.with_index(@keep) do
      test "readable line #{i} stays" do
        {msg, part} = {unquote(msg), unquote(part)}
        out = shown(msg)
        assert String.contains?(out, part), "#{msg} -> #{out}"
      end
    end
  end

  describe "ascii_line" do
    test "ASCII only, folded and not dropped" do
      out = shown("Résumé – café “ok” 中文\ttab\nnewline")
      assert out |> String.to_charlist() |> Enum.all?(&(&1 >= 32 and &1 < 127))
      assert String.contains?(out, "Resume - cafe")
      assert String.contains?(out, ~s("ok"))
      assert String.contains?(out, "??")
    end

    test "collapses runs of spaces, strips, folds the odd characters" do
      assert B.ascii_line("  a    b…c→d·e  ") == "a b...c->d-e"
      assert B.ascii_line("a\x01b\x7Fc") == "a?b?c"
    end

    test "cut to the screen" do
      long = shown(String.duplicate("x", 1000))
      assert String.length(long) <= 240
      assert String.ends_with?(long, "...")
      assert B.ascii_line(String.duplicate("y", 20), 10) == "yyyyyyy..."
    end
  end

  # A journal entry as the JSON gives it: string keys.
  defp e(extra),
    do: Map.merge(%{"PRIORITY" => "6", "MESSAGE" => "hello"}, Map.new(extra, fn {a, b} -> {to_string(a), b} end))

  describe "the allow-list" do
    test "kernel" do
      assert {"kernel", "kernel", false, "hello"} = B.entry_line(e(_TRANSPORT: "kernel"), "alnasl")
      assert B.entry_line(e(_TRANSPORT: "kernel", PRIORITY: "7"), "alnasl") == nil
      assert {_, "error", true, _} = B.entry_line(e(_TRANSPORT: "kernel", PRIORITY: "3"), "alnasl")
    end

    test "units" do
      assert {"nunki", "app", _, _} = B.entry_line(e(_SYSTEMD_UNIT: "nunki.service"), "nunki")
      assert {"alnasl", "box", _, _} = B.entry_line(e(_SYSTEMD_UNIT: "alnasl.service"), "nunki")
      assert {"network", "network", _, _} = B.entry_line(e(_SYSTEMD_UNIT: "systemd-networkd.service"), "polis")
      assert {"setup", "box", _, _} = B.entry_line(e(_SYSTEMD_UNIT: "alnasl-setup.service"), "polis")
      assert {"docker", "box", _, _} = B.entry_line(e(_SYSTEMD_UNIT: "docker.service"), "polis")
      assert B.entry_line(e(_SYSTEMD_UNIT: "sshd.service"), "alnasl") == nil
      assert B.entry_line(e(_SYSTEMD_UNIT: "session-3.scope"), "alnasl") == nil
      assert B.entry_line(e(_SYSTEMD_UNIT: "systemd-logind.service"), "alnasl") == nil
    end

    test "systemd's own lines" do
      assert {"systemd", "systemd", false, _} =
               B.entry_line(e(_PID: "1", UNIT: "nunki.service", MESSAGE: "Started nunki.service."), "nunki")

      assert {"systemd", "systemd", false, _} =
               B.entry_line(e(_PID: "1", UNIT: "x.target", MESSAGE: "Reached target X."), "nunki")

      assert B.entry_line(e(_PID: "1", UNIT: "getty@tty2.service", MESSAGE: "Started getty."), "nunki") == nil

      assert {"systemd", "error", true, _} =
               B.entry_line(
                 e(_PID: "1", UNIT: "weird.service", PRIORITY: "4", MESSAGE: "Failed to start weird.service."),
                 "nunki"
               )

      assert {_, "error", true, text} =
               B.entry_line(
                 e(
                   _PID: "1",
                   UNIT: "x.service",
                   PRIORITY: "3",
                   MESSAGE: "x.service: Failed with result 'exit-code'. psk=abc"
                 ),
                 "nunki"
               )

      refute String.contains?(text, "abc")

      # "ailed" or "rror" in the message makes it a failure whatever the priority says
      assert {_, "error", true, _} =
               B.entry_line(e(_PID: "1", UNIT: "weird.service", MESSAGE: "Some error here"), "nunki")
    end

    test "messages that are not text" do
      assert {_, _, _, "hi"} = B.entry_line(e(_SYSTEMD_UNIT: "nunki.service", MESSAGE: [104, 105]), "nunki")
      assert B.entry_line(e(_SYSTEMD_UNIT: "nunki.service", MESSAGE: "   "), "nunki") == nil
      assert B.entry_line(e(_SYSTEMD_UNIT: "nunki.service", MESSAGE: [300]), "nunki") == nil
      assert B.entry_line(e(_SYSTEMD_UNIT: "nunki.service", MESSAGE: 5), "nunki") == nil
      # a priority that is no number counts as info
      assert B.entry_line(e(_SYSTEMD_UNIT: "nunki.service", PRIORITY: "x"), "nunki") != nil
    end

    test "format_line pads the tag to eight" do
      assert B.format_line("kernel", "hi") == "kernel   hi"
      assert B.format_line("verylongtag", "hi") == "verylong hi"
    end
  end

  describe "the status line" do
    test "count, text" do
      st = %{
        "a.service" => %{"ActiveState" => "active", "UnitFileState" => "enabled"},
        "b.service" => %{"ActiveState" => "activating", "UnitFileState" => "enabled"},
        "c.service" => %{"ActiveState" => "inactive", "UnitFileState" => "disabled"},
        "d.service" => %{
          "ActiveState" => "inactive",
          "Type" => "oneshot",
          "Result" => "success",
          "UnitFileState" => "enabled",
          "InactiveEnterTimestampMonotonic" => "123"
        },
        "e.service" => %{"ActiveState" => "failed", "UnitFileState" => "enabled"}
      }

      assert B.count(st, Map.keys(st) ++ ["missing.service"]) == {2, 4, 1}
      assert B.status_text("nunki", "en", 7, 12, 0) == "starting nunki - 7 of 12 up"
      assert B.status_text("nunki", "nl", 7, 12, 1) == "nunki starten - 7 van 12 actief, 1 mislukt"
      assert B.status_text("polis", "en", 12, 12, 0) == "polis is up"
      assert B.status_text("polis", "nl", 12, 12, 0) == "polis staat klaar"
      assert B.status_text("polis", "en", 0, 0, 2) == "starting polis - 0 of 0 up, 2 failed"
    end

    test "role comes from /run/alnasl-mode/role, alnasl when unknown" do
      Box.root!()
      assert B.role() == "alnasl"
      Box.put("/run/alnasl-mode/role", "nunki\n")
      assert B.role() == "nunki"
      Box.put("/run/alnasl-mode/role", "bogus\n")
      assert B.role() == "alnasl"
    end

    test "unit_states parses systemctl show, status/1 counts" do
      Box.root!()
      Box.put("/run/alnasl-mode/role", "polis")

      Box.runner!(fn ["systemctl", "show", "-p", _props | units] ->
        out =
          for u <- units, do: "Id=#{u}\nActiveState=active\nSubState=running\nUnitFileState=enabled\nType=simple\n\n"

        {0, Enum.join(out)}
      end)

      assert %{"alnasl-data.service" => %{"ActiveState" => "active"}} = B.unit_states(["alnasl-data.service"])
      st = B.status("en")
      assert %{"role" => "polis", "up" => 12, "expected" => 12, "failed" => 0, "text" => "polis is up"} = st
      assert B.status("nl")["text"] == "polis staat klaar"
    end

    test "status without systemctl" do
      Box.root!()
      Box.runner!(fn _ -> {127, "nope"} end)
      assert %{"up" => 0, "expected" => 0, "text" => "starting alnasl - 0 of 0 up"} = B.status("en")
    end
  end

  describe "Follower" do
    @describetag :unix

    defp journal(lines) do
      body = Enum.map_join(lines, "", &(JSON.encode!(&1) <> "\n"))
      ["sh", "-c", "printf '%s' \"$1\"; sleep 30", "sh", body]
    end

    defp poll_until(f, want, tries \\ 50, acc \\ [])
    defp poll_until(f, _want, 0, acc), do: {acc, f}

    defp poll_until(f, want, tries, acc) do
      {lines, f} = Follower.poll(f, 0.2)
      acc = acc ++ lines
      if length(acc) >= want, do: {acc, f}, else: poll_until(f, want, tries - 1, acc)
    end

    test "reads journal lines, applies the allow-list and the role, and catches up" do
      cmd =
        journal([
          %{"PRIORITY" => "6", "_TRANSPORT" => "kernel", "MESSAGE" => "usb 1-1: new device"},
          %{"PRIORITY" => "6", "_SYSTEMD_UNIT" => "sshd.service", "MESSAGE" => "hidden"},
          %{"PRIORITY" => "6", "_SYSTEMD_UNIT" => "nunki.service", "MESSAGE" => "up psk=abc"},
          %{"PRIORITY" => "7", "_TRANSPORT" => "kernel", "MESSAGE" => "debug"}
        ])

      f = Follower.new(fn -> "nunki" end, cmd)
      assert f.caught_up == false
      {lines, f} = poll_until(f, 2)

      assert lines == [
               {"kernel", "kernel", false, "usb 1-1: new device"},
               {"nunki", "app", false, "up psk=***"}
             ]

      {[], f} = Follower.poll(f, 0.1)
      assert f.caught_up
      Follower.close(f)
    end

    test "a partial last line waits for its newline; junk lines are skipped" do
      body = ~s(not json\n{"PRIORITY":"6","_TRANSPORT":"kernel","MESSAGE":"one"}\n{"PRIORITY":"6","_TRANS)
      f = Follower.new(fn -> "alnasl" end, ["sh", "-c", "printf '%s' \"$1\"; sleep 30", "sh", body])
      {lines, f} = poll_until(f, 1)
      assert [{"kernel", "kernel", false, "one"}] = lines
      {[], f} = Follower.poll(f, 0.2)
      Follower.close(f)
    end

    test "starts again when the process ends, but not more often than every two seconds" do
      line = JSON.encode!(%{"PRIORITY" => "6", "_TRANSPORT" => "kernel", "MESSAGE" => "again"}) <> "\n"
      f = Follower.new(fn -> "alnasl" end, ["echo", String.trim(line)])
      {first, f} = poll_until(f, 1)
      assert [{"kernel", "kernel", false, "again"}] = first
      # the process has ended; the next poll notices and may not restart yet
      {[], f} = Follower.poll(f, 0.3)
      {second, f} = poll_until(f, 1, 40)
      assert [{"kernel", "kernel", false, "again"}] = second
      Follower.close(f)
    end

    test "a command that cannot start gives no lines and no crash" do
      f = Follower.new(fn -> "alnasl" end, ["/nonexistent/journalctl"])
      {[], f} = Follower.poll(f, 0.0)
      Follower.close(f)
    end

    test "close kills the child" do
      f = Follower.new(fn -> "alnasl" end, ["sleep", "30"])
      {_, f} = Follower.poll(f, 0.1)
      {:os_pid, pid} = Port.info(f.port, :os_pid)
      Follower.close(f)
      Process.sleep(200)
      {_, rc} = System.cmd("sh", ["-c", "kill -0 \"$1\"", "sh", Integer.to_string(pid)], stderr_to_stdout: true)
      assert rc != 0
    end
  end
end
