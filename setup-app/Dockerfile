# Builds the box's own programs (setup-app: the setup server, the hotspot and its portal, the boot screen
# painter, the system updater) as an aarch64 release inside an arm64 container (qemu-user on the build VM),
# the way arkab/Dockerfile builds Arkab. Debian 12 "bookworm": glibc 2.36, the same as Photon 5.0. The source
# is `git archive HEAD:setup-app` of this repository (build.ps1), so the image ships what is committed.
FROM --platform=linux/arm64 hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim

# gcc for alnasl-fbtool (the two ioctls the painter needs); openssl, flock (util-linux) and zstd for the tests
# that sign, verify, lock and unpack for real.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates openssl util-linux zstd xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY src/ /src/
# What the tests read from the repository (../../overlay, ../../scripts from /src/test): staged by scripts/build-setup.sh.
COPY overlay/ /overlay/
COPY scripts/ /scripts/

ENV LANG=C.UTF-8 ERL_FLAGS="+S 8:8" MAKEFLAGS=-j8
# The tests first, on the target architecture: they include the :unix ones a Windows PC skips.
RUN mix local.hex --force && mix local.rebar --force \
 && MIX_ENV=test mix test \
 && rm -rf _build/test
RUN mkdir -p rel/overlays/bin \
 && gcc -O2 -Wall -Werror -o rel/overlays/bin/alnasl-fbtool c_src/alnasl-fbtool.c \
 && MIX_ENV=prod mix release alnasl_setup --overwrite

# What the release must hold, and the C library it was built against.
RUN rel=/src/_build/prod/rel/alnasl_setup \
 && for needed in bin/alnasl_setup bin/alnasl-fbtool releases/COOKIE; do \
      [ -e "$rel/$needed" ] || { echo "the release has no $needed"; exit 1; }; done \
 && ldd $rel/erts-*/bin/beam.smp \
 && ldd $rel/bin/alnasl-fbtool \
 && getconf GNU_LIBC_VERSION \
 && $rel/bin/alnasl_setup eval 'IO.puts(:ok)' \
 && mkdir /out && tar -czf /out/alnasl-setup-linux-aarch64.tar.gz -C /src/_build/prod/rel --transform 's,^alnasl_setup,alnasl-setup,' alnasl_setup
