# The kiosk: Chromium full screen on the HDMI output of the hall box, shown by
# cage (a one-window Wayland compositor). If cage cannot start on a given
# GPU/driver, kiosk.sh falls back to a bare X server on the framebuffer.
# v5: external-page Back bar in the extension, X is the default path (cage only behind a watchdog), modesetting driver.
# v4: managed policies (no password/autofill/translate/sign-in prompts), wlr-randr + kiosk-res (resolution), OSK extension.
# v2: matchbox (a tiny window manager) so the X fallback really goes full screen;
# /opt/kiosk-ext is the corner menu button extension.
# Software rendering throughout: the image's kernel has no v3d driver.
FROM --platform=linux/arm64 debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cage chromium seatd wlr-randr \
      libgl1-mesa-dri libegl1 libgles2 mesa-utils-bin libgbm1 \
      xserver-xorg-core xserver-xorg-video-fbdev xserver-xorg-input-libinput xinit x11-xserver-utils matchbox-window-manager \
      libinput-bin udev xkb-data fonts-dejavu-core fonts-noto-color-emoji \
      procps curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /usr/share/locale/*

COPY ext /opt/kiosk-ext
COPY policies.json /etc/chromium/policies/managed/alnasl-kiosk.json
COPY kiosk.sh /kiosk.sh
COPY kiosk-res.sh /usr/local/bin/kiosk-res
RUN chmod 0755 /kiosk.sh /usr/local/bin/kiosk-res && chmod 0644 /etc/chromium/policies/managed/alnasl-kiosk.json && grep -q -a '/etc/chromium/policies' /usr/lib/chromium/chromium && echo 'policy path is known to this Chromium build'
ENTRYPOINT ["/kiosk.sh"]
