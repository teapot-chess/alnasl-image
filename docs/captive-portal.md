# The setup hotspot and its captive portal (v7.3)

A hall box with no screen, no keyboard and no network still has to be told which Wi-Fi to use. So it
opens a Wi-Fi of its own, a phone joins it, and the phone's own "is this network behind a sign-in page?"
check opens the box's setup page. No app, no cable, no screen.

## When the hotspot is on

`decide()` in `overlay/usr/local/lib/alnasl-setup/hotspot.py`, tested by `scripts/test-hotspot.py`:

| Situation | Hotspot |
|---|---|
| first 60 s after boot | off (a saved network gets its chance) |
| no network (no Ethernet address, no Wi-Fi client) after those 60 s | on, until the box has a network |
| on Ethernet | on for the first 10 minutes after boot, then off |
| a Wi-Fi client | off |
| a join from the page failed | on again for at least 10 minutes, whatever else holds |
| the reason went, a phone is still connected | lingers up to 10 minutes |
| lost a network it had earlier this boot | on after 5 minutes (a router rebooting is not a reason) |
| `HOTSPOT=off` in the file, or no `wlan0` | never |

wlan0 is a Wi-Fi client (wpa_supplicant) or the access point (hostapd), never both: the Pi's chip does
not do AP and client at once reliably. When saved networks exist and nobody is on the hotspot, it steps
aside for 45 s every 5 minutes (every 2 after a lost network) so the supplicant can find one that came back.

When someone picks a network on the page, the box drops the hotspot and tries it (40 s to associate, 15 s
more for an address). On success the hotspot stays off and the boot file's `# Box:` line says where the box
went. On failure the old Wi-Fi configuration is put back, the hotspot comes back, and the page says why:
wrong password, network not found, refused, or no address.

## Identity

- SSID `Alnasl-setup-XXXX`, the last four hex digits of the wlan0 MAC.
- WPA2-PSK, CCMP. Never open: with no valid password there is no hotspot at all.
- The password is the `PASSWORD=` line of `alnasl-hotspot.txt` on the boot partition (FAT, readable on any
  PC). The file ships with the line empty. At the first boot the box generates 10 characters (no 0/O/o,
  1/l/I) and writes them back, with the SSID. A Pi has no printed serial, so anyone who wants one password
  for every box fills the line in before the first boot (8 to 63 printable ASCII). A password that is not
  valid is replaced, and the file says so.
- `alnasl-hotspot-qr.png` next to it: `WIFI:T:WPA;S:<ssid>;P:<password>;;` with `\ ; , : "` escaped,
  10 px per module and a 4-module border. It is rewritten when the SSID or the password changes, which is
  how a card moved to another box gets the right sticker. Print it and stick it on the case.
- The box's own screen shows SSID and password while the hotspot is on (`/api/hotspot`, loopback only).
- hostapd is given the derived PSK (`wpa_psk=`), never the passphrase. The password goes to no log line
  and no command line. The QR stamp in `/var/lib/alnasl-setup` is a hash.

## Pieces

| Piece | What | Why this one |
|---|---|---|
| `alnasl-hotspot.service` → `hotspot.py` | the decision, the mode switch, the file and the QR | the only thing that touches wlan0's mode |
| `alnasl-hotspot-ap.service` → `/usr/sbin/hostapd` | the access point | Photon 5 has no hostapd package, and its wpa_supplicant is built without AP mode ("AP mode support not included in the build"). Taken from Debian bookworm arm64 like `iw` (`scripts/build-hostapd.sh`): same glibc 2.36, needs only libnl-3/genl/route and OpenSSL 3, which Photon ships; ldd-checked in the image |
| `alnasl-hotspot-dns.service` → dnsmasq | DHCP 10.42.0.10-250/24, DNS answering every name with 10.42.0.1, no option 114 | Photon's own `dnsmasq` package (release repo). The stock `dnsmasq.service` is masked |
| `alnasl-portal.service` → `portal.py` | HTTP on 10.42.0.1:80 | stdlib Python. DynamicUser, `CAP_NET_BIND_SERVICE` only, ProtectSystem=strict |
| `alnasl_qr.py` | the QR code | no qrencode in Photon. Pure Python (byte mode, level M, versions 1-10), checked by an independent decoder in `scripts/test-qr.py` |
| `arkab_live.py` | Arkab's join link | Arkab has no API for it (only its LiveView `join` event) and runs without distribution, so this is a small LiveView websocket client on loopback, which is what Arkab counts as "local" |

The box is 10.42.0.1/24 through a runtime networkd file, `/run/systemd/network/05-alnasl-hotspot.network`.
Forwarding is off on wlan0, and there is no NAT and no upstream DNS. A phone on the hotspot can reach the
setup page and nothing else.

## Captive-portal detection

DNS sends every name to 10.42.0.1. The portal answers every request whose `Host` is not `10.42.0.1` with
a `302` to `http://10.42.0.1/`. That is the wrong answer to every OS probe, and a wrong answer is what
makes the OS show its sign-in sheet. Nothing ever returns `204` or `Success`.

| Who | Probe | Expects when online |
|---|---|---|
| iOS / macOS | `http://captive.apple.com/hotspot-detect.html`, `http://www.apple.com/library/test/success.html` | `Success` page |
| Android | `http://connectivitycheck.gstatic.com/generate_204`, `clients3.google.com/generate_204`, `www.google.com/gen_204`, `connectivitycheck.android.com/generate_204` | `204` |
| Windows | `http://www.msftconnecttest.com/connecttest.txt` (then `/redirect`), `www.msftncsi.com/ncsi.txt` | `Microsoft Connect Test` |
| Firefox | `http://detectportal.firefox.com/canonical.html`, `/success.txt` | `success` |
| GNOME / NetworkManager | `http://nmcheck.gnome.org/check_network_status.txt` | `NetworkManager is online` |

RFC 8908's API answers at `http://10.42.0.1/api/captive`, but DHCP option 114 (RFC 8910) does not point to
it: the option must name an HTTPS URL, a box with no certificate cannot offer one, and a client that reads
the option and then refuses the URL may skip its probe and show nothing at all. The probes do the work. HTTPS probes fail outright (nothing listens on 443), which every OS also reads as "not online".

## The page

EN and NL ("je"), built for the iOS captive sheet: plain HTML and JS from the box, no outside resources,
and nothing that needs a clipboard API (pasting into a field is enough).

- Wi-Fi: scan (the list saved just before the hotspot took the radio, or a live AP-mode scan where the chip
  allows it), pick or type a network, password, hidden, country, Connect.
- Arkab box only: set the remote PIN (4 to 64 characters, the same rules as `alnasl-arkab-pin.txt`). It goes
  through the same hand-off, `/var/lib/arkab/pin-request`, 0600, owner arkab, and Arkab restarts to apply
  it. Then paste the join link. With a network beside the hotspot, it is handed to Arkab at once. Without
  one, it waits up to 15 minutes and is handed over once the Wi-Fi works. The page shows the result.
- Read-only: the role, the box's addresses, where it can be reached next (`<name>.local`, its page), and an
  "open in your browser" link, `http://10.42.0.1/`, for when the sign-in sheet is too cramped.

## Security limits, stated plainly

- Whoever has the hotspot password (or the QR sticker) can change the box's Wi-Fi and, on an Arkab box, its
  PIN and its server. That is the point of it. Keep the sticker on the box, not in a shared drive.
- The portal is plain HTTP inside a WPA2 network: confidential against the hall, not against someone who
  has the password.
- The portal passes exactly five calls to the setup server: `GET /api/portal`, `GET /api/portal/scan`,
  `POST /api/portal/join`, `POST /api/portal/arkab-pin`, `POST /api/portal/arkab-join`. Factory reset,
  updates, the role, power, diagnostics and `/api/hotspot` (which shows the password) are not on the list,
  and `scripts/test-hotspot.py` checks that. POSTs need the `X-Alnasl-Setup` header, as on the box itself.
- The firewall (`alnasl-firewall`) opens DNS (53), DHCP (67) and HTTP (80) only while
  `/run/alnasl-hotspot/active` exists, only `-i wlan0`, and only to 10.42.0.1. Everything else from wlan0
  is dropped while the hotspot is up, including the role's own port; IPv6 on wlan0 is dropped whole. Never
  anything on Ethernet. It stays fail-open, as before: a ruleset that does not load leaves the box reachable
  rather than bricked.
- No remote shell, no SSH, no way to run a command. The worst a phone can do is pick the wrong Wi-Fi, and
  the box comes back with the hotspot after a failure.
- The setup server itself stays on 127.0.0.1:4041. The portal reaches it over loopback.

## Testing

qemu has no Wi-Fi, so neither `verify.sh` nor `qemu-smoke.sh` can bring up the radio. What they do check:
units exist and are ordered; the firewall never opens 53/67/80 on Ethernet or without the flag; WPA2 only;
the file ships with its header and an empty password; no log line carries a secret; hostapd and dnsmasq
are present with all their libraries; `dnsmasq --test` accepts the configuration; `test-hotspot.py` and
`test-qr.py` pass on the image's Python. The rest is the hardware checklist:

1. **No network, iPhone**: boot with no cable and no saved Wi-Fi. After about a minute `Alnasl-setup-XXXX`
   appears and the screen (if any) shows SSID and password. Join it, scanning the QR from the card. The
   sign-in sheet opens by itself.
2. **Android**: the same; "Sign in to Wi-Fi network" notification, tap it, the page opens.
3. **Laptop** (macOS and Windows): the same, the OS opens a browser on the page. Also open
   `http://10.42.0.1/` by hand.
4. **Wrong password**: pick the hall's network with a wrong password. The hotspot drops, comes back within
   about a minute, and the page says "wrong password". It stays up for 10 minutes.
5. **Not found / no address**: a typo in a hidden SSID gives "not found". A network whose DHCP is off gives
   "no address".
6. **Success**: the right password. The hotspot goes and stays gone. `alnasl-hotspot.txt` gets a `# Box:`
   line with the address and name. The box answers on `<name>.local`.
7. **Ethernet**: boot with a cable. The hotspot is there for 10 minutes, then gone (unless a phone is still
   on it: then up to 10 more). From the LAN, `nmap -p 53,67,80` on the box shows them closed the whole time.
8. **Password file**: after the first boot, the card in a PC shows `PASSWORD=` filled, `SSID=` set and
   `alnasl-hotspot-qr.png` that a phone camera joins. Set your own password, boot, and the QR changes.
   Set `PASSWORD=short`: replaced, with a note. `HOTSPOT=off`: no hotspot.
9. **Arkab box**: on the page, set a PIN, then check Arkab's page asks for it. Paste a join link from the
   server's "Add a bridge" and pick the Wi-Fi. Once on the network the bridge appears on the server, and the
   page (when reopened through the hotspot, or the `# Box:` line) says "joined".
10. **Pi 3B+**: items 1, 4 and 6 again (other chip, same driver family).
11. **Journal**: `journalctl -u alnasl-hotspot -u alnasl-portal -u alnasl-hotspot-dns` contains neither the
    hotspot password nor the Wi-Fi passphrase nor the PIN. (Read on the box's own screen: there is no SSH.)
