"""Resolution logic of the settings server, with a fake screen and a stubbed live apply. Run with the image's python."""
import os
import sys
import time
import tempfile

sys.path.insert(0, "/usr/local/lib/alnasl-setup")
import server  # noqa: E402

tmp = tempfile.mkdtemp()
server.KIOSK_CONF = tmp + "/kiosk.conf"
server.RES_CONFIRM_SECONDS = 1
server.write_atomic(server.KIOSK_CONF, 'KIOSK_SCALE="125"\n')
calls = []
state = {"ok": True, "running": True}
server.drm_connector = lambda: ("HDMI-A-1", ["1920x1080", "1280x720", "1024x768"])
server.kiosk_res_live = lambda conn, mode: (calls.append((conn, mode)) or (state["ok"], "stub"))
server.unit_state = lambda u: {"enabled": True, "active": state["running"]}
server.restart_kiosk = lambda: calls.append("restart")
server.KIOSK_STATE = tmp + "/state"
server.write_atomic(server.KIOSK_STATE, "path=cage mode=1920x1080\n")


def conf():
    return server.get_kiosk_conf()


def expect(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        sys.exit(1)


r = server.res_status()
expect(r["modes"][0] == "1920x1080" and r["setting"] == "auto" and r["connector"] == "HDMI-A-1", "status lists the modes, default auto")
try:
    server.set_resolution("800x600")
    expect(False, "a mode the screen does not offer is refused")
except ValueError:
    expect(True, "a mode the screen does not offer is refused")
try:
    server.set_resolution("1x1; reboot")
    expect(False, "garbage is refused")
except ValueError:
    expect(True, "garbage is refused")

# apply + confirm
j = server.set_resolution("1280x720")
expect(j["pending"] and conf()["KIOSK_RES"] == "1280x720" and conf()["KIOSK_SCALE"] == "125", "apply saves the mode and keeps the scale setting")
expect(server.res_status()["pending"], "pending until confirmed")
server.confirm_resolution()
time.sleep(3.5)
expect(conf()["KIOSK_RES"] == "1280x720" and ("HDMI-A-1", "auto") not in calls, "a confirmed mode stays after the timer would have fired")

# apply + no answer -> automatic revert to the previous mode
calls.clear()
server.set_resolution("1024x768")
time.sleep(3.8)
expect(conf()["KIOSK_RES"] == "1280x720" and calls[-1] == ("HDMI-A-1", "1280x720"), "no confirmation: back to the previous mode, applied live")
expect(not server.res_status()["pending"], "nothing pending afterwards")

# apply + Undo, and two changes in a row go back to the ORIGINAL
calls.clear()
server.set_resolution("1024x768")
server.set_resolution("1920x1080")
server.cancel_resolution()
expect(conf()["KIOSK_RES"] == "1280x720", "undo after two changes returns to the original mode")

# the live apply fails (black screen risk): refused and nothing saved
state["ok"] = False
try:
    server.set_resolution("1024x768")
    expect(False, "failed live apply is reported")
except ValueError:
    expect(conf()["KIOSK_RES"] == "1280x720", "failed live apply is reported and not saved")
state["ok"] = True

# revert whose live apply fails: restart the kiosk, which applies the saved value
calls.clear()
server.set_resolution("auto")
state["ok"] = False
server.cancel_resolution()
expect("restart" in calls and conf()["KIOSK_RES"] == "1280x720", "revert that cannot be applied live restarts the screen (it applies the saved mode)")
state["ok"] = True

# X on fbdev cannot switch live: saved + the screen restarts + a longer confirm window; revert restarts again
server.write_atomic(server.KIOSK_STATE, "path=x driver=fbdev window-size=1920,1080\n")
state["ok"] = False
calls.clear()
server.cancel_resolution()
j = server.set_resolution("1280x720")
expect(j["restart"] and j["pending"] and "restart" in calls and conf()["KIOSK_RES"] == "1280x720" and j["confirm_seconds"] > 20, "fbdev X: saved, screen restarts, longer confirm window")
calls.clear()
server.cancel_resolution()
expect(conf()["KIOSK_RES"] == "auto" or conf()["KIOSK_RES"] == "1280x720", "undo after an X restart runs")
state["ok"] = True
server.write_atomic(server.KIOSK_STATE, "path=cage mode=1920x1080\n")

# kiosk not running: saved only, nothing pending
state["running"] = False
j = server.set_resolution("1024x768")
expect(j["pending"] is False and conf()["KIOSK_RES"] == "1024x768", "screen stopped: saved for the next start, no countdown")
print("all resolution checks passed")
