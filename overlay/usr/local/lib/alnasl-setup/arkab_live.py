"""Joins Arkab to a server from the setup page: Arkab's own page, driven over loopback.

Arkab (0.5.x) has no API for joining; its status page does it, a Phoenix LiveView, and only for a
visitor on the machine itself (ArkabWeb.Local: a loopback peer without proxy headers). So this is a
very small LiveView client: it loads http://127.0.0.1:4050/, opens the page's websocket with the
page's own CSRF token and session, joins the view and submits the "join" form with the link, exactly as
the browser on the box's screen would. Then it reads the answers until the page says how it went.
Python standard library only; a websocket client in 80 lines is not elegant, but neither is a hall box
nobody can set up.

    join(link) -> (ok: bool, reason: str)   reason: joined, not_a_link, used_or_expired, unreachable,
                                            version, elsewhere, not_a_server, arkab_down, arkab_refused, no_answer

Arkab is asked in English (Accept-Language: en); the words below are its English words for each result
(lib/arkab_web/words.ex), and the setup page says them in its own words, in its own language.
"""
import base64
import json
import os
import re
import socket
import time
from urllib.parse import quote, urlsplit

HOST, PORT = "127.0.0.1", 4050
LINK_RE = re.compile(r"^https?://[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?/join/[A-Za-z0-9_\-]{1,64}$")
RESULTS = [  # (Arkab's words, our reason)
    ("Joined.", "joined"),
    ("not a join link", "not_a_link"),
    ("used up or expired", "used_or_expired"),
    ("does not answer from here", "unreachable"),
    ("another version of the link", "version"),
    ("another hall", "elsewhere"),
    ("not like a server", "not_a_server"),
]


def valid_link(link):
    """Arkab's own rule (Arkab.Bridge.Join.parse/1), narrower: what a join link of a server looks like."""
    link = (link or "").strip()
    if not LINK_RE.fullmatch(link):
        return None
    u = urlsplit(link)
    if u.port is not None and not 0 < u.port < 65536:
        return None
    return link


class _WS:
    def __init__(self, sock):
        self.s = sock
        self.buf = b""

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text, opcode=1):
        data = text.encode() if isinstance(text, str) else text
        head = bytes([0x80 | opcode])
        n = len(data)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + n.to_bytes(2, "big")
        else:
            head += bytes([0x80 | 127]) + n.to_bytes(8, "big")
        key = os.urandom(4)
        self.s.sendall(head + key + bytes(b ^ key[i % 4] for i, b in enumerate(data)))

    def recv(self):
        """The next text message (fragments joined); answers pings; None when the server closes."""
        msg = b""
        while True:
            b1, b2 = self._read(2)
            op, n = b1 & 0x0F, b2 & 0x7F
            if n == 126:
                n = int.from_bytes(self._read(2), "big")
            elif n == 127:
                n = int.from_bytes(self._read(8), "big")
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if op == 8:
                return None
            if op == 9:
                self.send(data, 10)
                continue
            if op in (0, 1, 2):
                msg += data
                if b1 & 0x80:
                    return msg.decode("utf-8", "replace")


def _http_get(path, timeout):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    try:
        s.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/html\r\nAccept-Language: en\r\n"
                   "Connection: close\r\n\r\n" % (path, HOST, PORT)).encode())
        data = b""
        while len(data) < 4000000:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    finally:
        s.close()
    head, _, body = data.partition(b"\r\n\r\n")
    return head.decode("latin-1"), body.decode("utf-8", "replace")


def _attr(html, name):
    m = re.search(r'(?<![\w-])%s="([^"]*)"' % re.escape(name), html)
    return m.group(1).replace("&quot;", '"').replace("&amp;", "&") if m else None


def join(link, timeout=45):
    link = valid_link(link)
    if not link:
        return False, "not_a_link"
    deadline = time.monotonic() + timeout
    try:
        head, html = _http_get("/", 10)
    except OSError:
        return False, "arkab_down"
    if not head.startswith("HTTP/1.1 200"):
        return False, "arkab_refused"
    cookies = "; ".join(m.group(1) for m in re.finditer(r"(?im)^set-cookie:\s*([^;\r\n]+)", head))
    csrf = re.search(r'<meta name="csrf-token" content="([^"]+)"', html)
    main = re.search(r"<div[^>]*data-phx-main[^>]*>", html)
    if not csrf or not main:
        return False, "arkab_refused"
    div = main.group(0)
    view_id, session, static = _attr(div, "id"), _attr(div, "data-phx-session"), _attr(div, "data-phx-static")
    if not view_id or session is None:
        return False, "arkab_refused"
    csrf = csrf.group(1)
    try:
        s = socket.create_connection((HOST, PORT), timeout=10)
    except OSError:
        return False, "arkab_down"
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(("GET /live/websocket?_csrf_token=%s&vsn=2.0.0 HTTP/1.1\r\nHost: %s:%d\r\n"
                   "Origin: http://%s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nCookie: %s\r\n"
                   "Accept-Language: en\r\n\r\n" % (quote(csrf, safe=""), HOST, PORT, HOST, PORT, key, cookies)).encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = s.recv(4096)
            if not chunk:
                return False, "arkab_refused"
            resp += chunk
        hdr, _, rest = resp.partition(b"\r\n\r\n")
        if b" 101 " not in hdr.split(b"\r\n")[0]:
            return False, "arkab_refused"
        ws = _WS(s)
        ws.buf = rest
        topic = "lv:" + view_id
        ws.send(json.dumps(["1", "1", topic, "phx_join", {
            "url": "http://%s:%d/" % (HOST, PORT),
            "params": {"_csrf_token": csrf, "_mounts": 0, "_mount_attempts": 0},
            "session": session, "static": static, "sticky": False}]))
        joined = False
        sent = False
        while time.monotonic() < deadline:
            s.settimeout(max(0.5, deadline - time.monotonic()))
            raw = ws.recv()
            if raw is None:
                return False, "no_answer"
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(msg, list) or len(msg) != 5:
                continue
            _jr, ref, _topic, event, payload = msg
            if not joined:
                if ref == "1" and event == "phx_reply":
                    if (payload or {}).get("status") != "ok":
                        return False, "arkab_refused"
                    joined = True
                    ws.send(json.dumps(["1", "2", topic, "event", {
                        "type": "form", "event": "join", "value": "link=" + quote(link, safe=""), "meta": {}}]))
                    sent = True
                continue
            if sent and event in ("diff", "phx_reply"):
                text = json.dumps(payload)
                for words, reason in RESULTS:
                    if words in text:
                        return reason == "joined", reason
        return False, "no_answer"
    except (OSError, ValueError, ConnectionError):
        return False, "no_answer"
    finally:
        try:
            s.close()
        except OSError:
            pass
