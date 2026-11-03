# Debug SSH images (v7.4)

Since v6 an Alnasl box has no remote login at all. That is right for a hall, and useless for a box on a test
bench that will not show up on the network: nothing to ask it what it is doing. `build.ps1 -DebugSsh` builds
the one exception, for testing only.

## What the switch does

- `openssh-server` stays in the image (a normal build removes it), `sshd.service` and `sshd-keygen.service` are
  enabled. Host keys are made on the box at its first start, never baked into the image.
- `/etc/ssh/sshd_config` starts with: `PermitRootLogin prohibit-password`, `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `AuthenticationMethods publickey`. sshd keeps the first value it reads,
  so the stock lines below cannot loosen them.
- `/root/.ssh/authorized_keys` is exactly `scripts/debug-ssh.pub` (`alnasl-debug-image`, ed25519). The private
  half lives on the PC that built it, as `~/.ssh/alnasl_debug`, and never in this repository or the image.
- `/etc/alnasl/debug-ssh` is the flag `alnasl-firewall` reads: with it, tcp/22 is accepted on Ethernet and
  Wi-Fi. The rule comes after the setup hotspot's wlan0 DROP, so phones on the hotspot still get nothing.
- `/etc/alnasl/image-release` gets `DEBUG_SSH=1`. `ALNASL_VERSION` stays a plain version (the updater parses
  it); the file name says the rest: copy it as `photon-alnasl-v7.4-spi-debugssh.img.xz` or similar.
- `verify.sh` prints a loud DEBUG SSH IMAGE banner and checks the opposite of a normal build: sshd enabled, the
  effective sshd configuration (`sshd -T`), the exact key, 22 open for every role and not from the hotspot.

Log in: `ssh -i ~/.ssh/alnasl_debug root@<the box's address>`.

## Never ship it

`build.ps1 -Release -DebugSsh` stops before it starts. `assemble.sh` refuses `ALNASL_DEBUG_SSH=1` with
`ALNASL_RELEASE=1`, and `verify.sh` fails such an image. A system update to a normal image replaces the slot,
and with it sshd, the key and the flag; the data partition never held any of them.

## In het kort (NL)

`build.ps1 -DebugSsh` maakt een testimage waarop je als root kunt inloggen met de debugsleutel, en alleen
daarmee: geen wachtwoord, geen andere sleutel. Poort 22 staat open op Ethernet en Wi-Fi, niet op de
setup-hotspot. Het image draagt `DEBUG_SSH=1` in `/etc/alnasl/image-release`. Inloggen doe je met
`ssh -i ~/.ssh/alnasl_debug root@<adres van de kast>`. Zo'n image lever je nooit uit: een `-Release`-build
weigert de schakelaar, en assemble.sh en verify.sh weigeren hem ook.
