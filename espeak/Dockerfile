# espeak-ng for the nunki role (docs/v7-plan.md, "Nunki on the box"). Photon has no espeak-ng package, so
# this takes Debian 12's arm64 build (glibc 2.36, the same as Photon 5.0): the program, libespeak-ng, libsonic
# and the voice data. Debian's libpcaudio also links PulseAudio and through it half a desktop; pcaudiolib is
# small, so it is built here with ALSA only and replaces that one. The box's own libasound (Photon's
# alsa-lib) is used at run time. Everything lands in /opt/espeak-ng; /usr/local/bin/espeak-ng (overlay) sets
# the two paths and runs it. Same base as the app builds (already on the VM, nothing new to pull).
FROM --platform=linux/arm64 hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends espeak-ng espeak-ng-data build-essential git ca-certificates \
      autoconf automake libtool pkg-config libasound2-dev \
 && rm -rf /var/lib/apt/lists/*

# pcaudiolib 1.2 (what bookworm ships), ALSA only.
RUN git clone --depth 1 --branch 1.2 https://github.com/espeak-ng/pcaudiolib /pca \
 && cd /pca && ./autogen.sh \
 && ./configure --prefix=/opt/espeak-ng --without-pulseaudio --without-qsl --without-coreaudio \
 && make -j8 && make install

RUN set -e; o=/opt/espeak-ng; a=/usr/lib/aarch64-linux-gnu; \
    mkdir -p $o/bin $o/lib $o/share; \
    cp -a /usr/bin/espeak-ng $o/bin/; \
    cp -a $a/libespeak-ng.so.1* $a/libsonic.so.0* $o/lib/; \
    cp -a $a/espeak-ng-data $o/share/; \
    rm -rf $o/include $o/lib/pkgconfig $o/lib/*.a $o/lib/*.la; \
    ls -la $o/lib; \
    LD_LIBRARY_PATH=$o/lib ldd $o/bin/espeak-ng | tee /tmp/ldd; \
    ! grep -q 'pulse\|not found' /tmp/ldd; \
    grep -q "$o/lib/libpcaudio.so.0" /tmp/ldd; \
    LD_LIBRARY_PATH=$o/lib ESPEAK_DATA_PATH=$o/share $o/bin/espeak-ng --voices=nl | head -n 3; \
    LD_LIBRARY_PATH=$o/lib ESPEAK_DATA_PATH=$o/share $o/bin/espeak-ng -v nl -w /tmp/t.wav "Ronde drie begint nu"; \
    test -s /tmp/t.wav; \
    cp /usr/share/doc/espeak-ng/copyright $o/COPYING.espeak-ng; cp /pca/COPYING $o/COPYING.pcaudiolib; \
    du -sh $o; \
    mkdir /out && tar -czf /out/espeak-ng-aarch64.tar.gz -C /opt espeak-ng
