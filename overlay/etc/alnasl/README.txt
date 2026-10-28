Alnasl hall box. The program is in /opt/alnasl, its data in /var/lib/alnasl,
its settings in /etc/alnasl/alnasl.env. Log: journalctl -u alnasl
Kiosk:    journalctl -u alnasl-kiosk
Firewall: journalctl -u alnasl-firewall
Boot screen: /usr/local/sbin/alnasl-splash (journalctl -u alnasl-splash)
OS updates: nightly 03:00-05:00, journalctl -u alnasl-os-update; results in /var/lib/alnasl-os-update
Reset to new: menu > Settings > Erase this box, or alnasl-reset.txt on the boot partition
No ssh, no VPN: this box is looked after from its own screen and keyboard.
