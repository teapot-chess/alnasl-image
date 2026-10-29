#!/usr/bin/python3
"""Alnasl hall box: the captive portal of the setup hotspot (docs/captive-portal.md).

Listens on 10.42.0.1:80 only, and only while the hotspot is up (alnasl-hotspot starts and stops it). It
runs as an unprivileged dynamic user with the one capability of binding port 80, holds no secret and
changes nothing itself: the page's few calls go to the setup server on 127.0.0.1:4041, and ONLY the
ones in PASS below (Wi-Fi, Arkab's PIN, Arkab's join link, and reading what the page shows). Factory
reset, updates, the role, power, diagnostics: not on the list, so not reachable from a phone, however
it asks.

Every phone OS finds out it is behind a portal by fetching a known URL and expecting a known answer
(Apple: captive.apple.com/hotspot-detect.html wants "Success"; Android: /generate_204 wants a 204;
Windows: /connecttest.txt wants "Microsoft Connect Test"; Firefox: /canonical.html). DNS on the hotspot
answers every name with 10.42.0.1, so all of those land here, and every request that is not for
10.42.0.1 itself gets a redirect to http://10.42.0.1/ - which is the wrong answer to each of them, and
the wrong answer is what makes the phone show its sign-in sheet.
"""
import http.client
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ADDR, PORT = "10.42.0.1", 80
SETUP = ("127.0.0.1", 4041)
WWW = "/usr/local/share/alnasl-setup/www"
PORTAL = "http://%s/" % ADDR
# What the page may ask of the setup server. Nothing else is passed on.
PASS_GET = ("/api/portal", "/api/portal/scan")
PASS_POST = ("/api/portal/join", "/api/portal/arkab-pin", "/api/portal/arkab-join")
STATIC = {"/": ("portal.html", "text/html; charset=utf-8"), "/index.html": ("portal.html", "text/html; charset=utf-8"),
          "/portal.js": ("portal.js", "text/javascript; charset=utf-8"), "/app.css": ("app.css", "text/css; charset=utf-8")}
# The OS probes, for the log and the docs; they all get the same redirect.
PROBES = ("/hotspot-detect.html", "/library/test/success.html", "/generate_204", "/gen_204", "/connecttest.txt",
          "/ncsi.txt", "/redirect", "/canonical.html", "/success.txt", "/kindle-wifi/wifistub.html")
MAX_BODY = 8192


def log(*a):
    print("alnasl-portal:", *a, flush=True)


def captive_json():
    """RFC 8908. Clients only believe it over HTTPS, which a box with no certificate cannot offer, so in
    practice the probes above do the work; it costs nothing to be right where someone does look."""
    return {"captive": True, "user-portal-url": PORTAL}


def setup_call(method, path, body=None, timeout=90):
    c = http.client.HTTPConnection(*SETUP, timeout=timeout)
    try:
        hdr = {"Host": "%s:%d" % SETUP}
        if method == "POST":
            hdr.update({"Content-Type": "application/json", "X-Alnasl-Setup": "1"})
        c.request(method, path, body=body, headers=hdr)
        r = c.getresponse()
        return r.status, r.read(200000)
    finally:
        c.close()


def route(method, host, path):
    """What to do with a request: ("redirect", url) | ("static", file, type) | ("captive",) |
    ("pass", path) | ("forbidden",). Pure, for the tests."""
    host = (host or "").lower()
    if host not in (ADDR, ADDR + ":80"):
        return ("redirect", PORTAL)  # every probe, every other site: the setup page
    if method == "GET":
        if path in STATIC:
            return ("static",) + STATIC[path]
        if path == "/api/captive":
            return ("captive",)
        if path in PASS_GET:
            return ("pass", path)
        if path.startswith("/api/"):
            return ("forbidden",)
        return ("redirect", PORTAL)
    if method == "POST" and path in PASS_POST:
        return ("pass", path)
    return ("forbidden",)


class H(BaseHTTPRequestHandler):
    server_version = "alnasl-portal"
    protocol_version = "HTTP/1.1"
    timeout = 60

    def log_message(self, fmt, *a):  # method, path, status; never a query or a body
        log(self.command, self.path.split("?")[0][:80], a[1] if len(a) > 1 else "")

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self, method):
        path = urlsplit(self.path).path
        what = route(method, self.headers.get("Host"), path)
        try:
            if what[0] == "redirect":
                body = ('<!doctype html><title>Alnasl setup</title><a href="%s">Alnasl setup</a>' % PORTAL).encode()
                return self._send(302, body, "text/html; charset=utf-8", {"Location": what[1]})
            if what[0] == "static":
                with open(os.path.join(WWW, what[1]), "rb") as f:
                    return self._send(200, f.read(), what[2])
            if what[0] == "captive":
                return self._send(200, captive_json(), "application/captive+json")
            if what[0] == "pass":
                body = None
                if method == "POST":
                    # Same rule as the setup server: a custom header and JSON, so no other origin can post.
                    if self.headers.get("X-Alnasl-Setup") != "1":
                        self.close_connection = True
                        return self._send(403, {"error": "forbidden"}, extra={"Connection": "close"})
                    n = int(self.headers.get("Content-Length") or 0)
                    if n > MAX_BODY:
                        self.close_connection = True
                        return self._send(413, {"error": "too large"}, extra={"Connection": "close"})
                    body = self.rfile.read(n)
                status, data = setup_call(method, what[1], body)
                return self._send(status, data)
            self.close_connection = True
            return self._send(403, {"error": "forbidden"}, extra={"Connection": "close"})
        except (OSError, http.client.HTTPException) as e:
            log(method, path, "setup server:", type(e).__name__)
            return self._send(502, {"error": "box_busy"})

    def do_GET(self):
        self._handle("GET")

    def do_HEAD(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")


def main():
    ThreadingHTTPServer.request_queue_size = 32
    ThreadingHTTPServer.allow_reuse_address = True
    srv = ThreadingHTTPServer((ADDR, PORT), H)
    srv.daemon_threads = True
    log("listening on %s:%d" % (ADDR, PORT))
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
