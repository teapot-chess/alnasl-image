Alnasl hall box (Raspberry Pi 4, Photon OS 5.0)

Optional files to put in this folder before the first boot:
  alnasl-wifi.txt          Wi-Fi name and passphrase   (see alnasl-wifi.txt.example)
  alnasl-reset.txt         RESET on the first line: erase this box back to new (see alnasl-reset.txt.example)
  alnasl-upgrade.txt       the next release train on the first line, e.g. v8 (see alnasl-upgrade.txt.example)
  alnasl-mode.txt          alnasl, arkab, polis or nunki on the first line: what this box is (see alnasl-mode.txt.example)
  alnasl-arkab-pin.txt     (already here) the remote PIN of an Arkab box: fill in the PIN= line; it is emptied again at boot
  alnasl-hotspot.txt       (already here) the password of the box's setup hotspot; leave PASSWORD= empty and the box makes one

The first four are read at boot and deleted; alnasl-arkab-pin.txt stays and only has its PIN line emptied. Do not edit config.txt or the other files here.
This box has no remote login (no ssh, no VPN): everything is done on its own screen, or, on a box with no screen and
no network, on the setup page of its own Wi-Fi: a box that has no network after a minute opens "Alnasl-setup-XXXX"
(WPA2; on Ethernet only for the first 10 minutes). Join it with a phone and the setup page opens by itself.
Everything else is described in the README that came with the image.

The folder "alnasl" holds the boot loader's choice between the two system slots (grubenv). Leave it alone.

Files that APPEAR here:
  alnasl-diagnostics-YYYYMMDD-HHMMSS.txt   written by the box's menu: Diagnostics > "Save diagnostics to the SD card".
                                           Plain text, passphrases and keys removed. Send it along when something does not work.
  alnasl-hotspot-qr.png                    a QR code that joins the setup hotspot (phone camera, no typing). Print it and
                                           stick it on the case. Written again whenever the password or the box changes.
                                           Whoever has it can open the setup page: keep it with the box, not on the web.
