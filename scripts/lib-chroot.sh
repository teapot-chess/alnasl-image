# Sourced on the build VM. Helpers to enter an aarch64 root through qemu-user.
cmount() { # root
  mount -t proc proc "$1/proc"; mount --rbind /sys "$1/sys"; mount --make-rslave "$1/sys"
  mount --rbind /dev "$1/dev"; mount --make-rslave "$1/dev"
  mount -t tmpfs tmpfs "$1/run" 2>/dev/null || true
}
cumount() {
  for m in dev sys proc run; do umount -R -l "$1/$m" 2>/dev/null || true; done
}
