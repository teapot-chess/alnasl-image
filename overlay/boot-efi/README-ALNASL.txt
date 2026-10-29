Alnasl hall box (Raspberry Pi 4, Photon OS 5.0)

Optional files to put in this folder before the first boot:
  alnasl-wifi.txt          Wi-Fi name and passphrase   (see alnasl-wifi.txt.example)
  alnasl-reset.txt         RESET on the first line: erase this box back to new (see alnasl-reset.txt.example)
  alnasl-upgrade.txt       the next release train on the first line, e.g. v8 (see alnasl-upgrade.txt.example)
  alnasl-mode.txt          alnasl, arkab, polis or nunki on the first line: what this box is (see alnasl-mode.txt.example)
  alnasl-arkab-pin.txt     (already here) the remote PIN of an Arkab box: fill in the PIN= line; it is emptied again at boot

The first four are read at boot and deleted; alnasl-arkab-pin.txt stays and only has its PIN line emptied. Do not edit config.txt or the other files here.
This box has no remote login (no ssh, no VPN): everything is done on its own screen.
Everything else is described in the README that came with the image.

The folder "alnasl" holds the boot loader's choice between the two system slots (grubenv). Leave it alone.

Files that APPEAR here:
  alnasl-diagnostics-YYYYMMDD-HHMMSS.txt   written by the box's menu: Diagnostics > "Save diagnostics to the SD card".
                                           Plain text, passphrases and keys removed. Send it along when something does not work.
