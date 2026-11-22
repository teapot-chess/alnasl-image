# Remote access (v7.5, opt-in)

Sometimes the box is in a hall forty kilometres away and the arbiter on the phone says "it's doing the thing
again". Remote access lets the box join **your own** Tailscale network so you can open its page and log in to
it from wherever you are. It is off in every image, every role, until somebody standing at the box presses
Start. Nobody is in by default, and nothing ships with a key.

## What is in the image

- `tailscale` and `tailscaled` 1.104.7, Tailscale's static arm64 build, pinned by version and sha256 in
  `scripts/assemble.sh` (the build stops if the download does not match).
- `alnasl-tailscale.service`: enabled, but gated by `ConditionPathExists=/var/lib/alnasl-tailscale/enabled`. No
  flag (the image as built), no daemon, no socket, no port.
- `/usr/local/sbin/alnasl-tailscale`: the only thing that talks to Tailscale. The setup app
  (`AlnaslSetup.Server.Remote`) calls it and nothing else; `/api/services` cannot touch Tailscale (verify.sh checks).
- State in `/var/lib/alnasl-tailscale` on the data partition (mode 0700): it survives updates and goes with Leave
  or a reset.

## The flow

Settings > Remote access (HDMI menu), or Menu > Remote access on the panel.

1. **Start.** The flag is written, the service starts, and the box runs
   `tailscale up --ssh --hostname=<host name> --netfilter-mode=off --accept-dns=false --accept-routes=false --timeout=0`.
   No auth key. Tailscale answers with a login link.
2. **Scan.** The menu shows the link as a big QR code and as text. Scan it with your phone, log in to Tailscale,
   and the box joins that account's network. If your tailnet wants new machines approved, the menu says so:
   approve it in the admin console (Machines).
3. **Connected.** The menu shows the tailnet address (100.x.y.z), the MagicDNS name and the network.
   From then on the panel's home screen shows a Tailscale line too: the address, with the app's port when the box
   runs one (100.x.y.z:4006), so you can read it off the box without opening the menu.

What the menu does with the odd cases:

| Case | What it shows |
|---|---|
| No answer 30 s after Start (no internet, DNS dead, Tailscale blocked) | "No answer from Tailscale. Is this box on the internet?", New code, Leave |
| The link is over ten minutes old | still the code, plus "may have expired" and New code (`tailscale up --force-reauth`) |
| Already logged in (a restart, an update) | Connected, straight away: the state is on the data partition |
| Logged out from elsewhere (key expired, removed in the console) | "Logged out", New code, Leave |
| Image without Tailscale, kernel without TUN | said in those words; nothing starts |

## Who can reach what

**On the hall's network: nothing new.** The firewall is exactly the same with remote access on or off as far as
eth0 and wlan0 are concerned. Port 41641 is not opened; tailscaled gets out through NAT traversal or Tailscale's
relays, which is slower but needs no hole in anything.

**On your tailnet, while remote access is on:**

- **The role's own page**, port 4040 (Alnasl), 4050 (Arkab), 4061 (Polis) or 4062 (Nunki), on `tailscale0` only.
  One rule per IP version, `-A ALNASL-IN -i tailscale0 -p tcp --dport <port> -j ACCEPT`, written by
  `alnasl-firewall` only while `/run/alnasl-tailscale/active` exists (the service's ExecStartPre writes it, its
  ExecStopPost removes it, each followed by a firewall reload). tailscaled runs with `--netfilter-mode=off`: it
  never writes iptables rules of its own. The firewall's fail-open logic is unchanged. Polis and Nunki normally
  listen on loopback only; while remote access is on they get `POLIS_LISTEN=lan` / `NUNKI_LISTEN=lan` through a
  runtime drop-in in `/run/systemd/system/` (gone at the next boot, removed at stop), and the firewall still lets
  their port in on `tailscale0` only. The box's **PIN still asks** on every page, exactly as in the hall.
- **The box itself, as root, through Tailscale SSH.** `--ssh` makes tailscaled answer SSH on the tailnet address
  itself. There is no OpenSSH, no password, no authorized_keys file: Tailscale decides who gets in, by your
  tailnet's ACL. The default ACL lets **the owner's own devices** in, and tailscaled asks you to re-check in the
  browser for root (the default `check` action). Anyone you share the machine with, or add to your tailnet with a
  permissive ACL, can be root on the box. That is the honest trade-off: the box is exactly as safe as your
  Tailscale account (use two-factor) and your ACL.
- The setup app (4041), the boot screen and the kiosk listen on loopback and stay there.

Not done, on purpose: no subnet routing, no exit node, no DNS from the tailnet (`--accept-dns=false`), no routes
from it (`--accept-routes=false`), no userspace networking (that would let tailnet connections reach the box's
loopback-only services).

## Revoking

- **At the box: Leave.** `tailscale logout` (the key is invalidated on Tailscale's side), the service stops, the
  flag and the state directory are wiped, the firewall rule and the drop-in go. The box is as built.
- **From anywhere: the Tailscale admin console.** Machines > the box > Remove (or tighten the ACL). The box loses access at once; its menu then shows "Logged out". Press Leave there too, so it
  forgets the old state.
- **A reset** (Settings > Reset) wipes the data partition, Tailscale's state with it.
- A box that is stolen while connected: remove it in the admin console. Its key is useless after that.

## Checks

`scripts/verify.sh`: the pinned binaries are arm64 and in place; the unit is enabled and gated; no flag, state or
key in the image; no auth key in the script or unit; the firewall without the flag has no Tailscale rule for any
role; with the flag each role gets exactly one extra rule per IP version, its own port on `tailscale0`, and
nothing else changes; the kernel has TUN; the setup server has no `sshd` and only Remote touches Tailscale.

Never tried on a Pi (as of 7.5): the whole flow. In particular kernel TUN on Photon's Pi kernel, and how
`tailscale up` behaves when the box's clock is still wrong at first boot (TLS will not like it).
