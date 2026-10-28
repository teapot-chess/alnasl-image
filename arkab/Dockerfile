# Builds the Arkab release for aarch64 inside an arm64 container (qemu-user on the build VM), the way
# alnasl/Dockerfile does for Alnasl. Debian 12 "bookworm" has glibc 2.36, the same as Photon 5.0, and Arkab's
# own install.sh wants 2.35 or newer. OTP 29 + Elixir 1.20 as in Arkab's CI. The source is `git archive` of
# the Arkab repo's HEAD (build.ps1), so the image ships exactly what is on main.
FROM --platform=linux/arm64 hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY src/ /src/

# ARKAB_UART=1: the serial library (circuits_uart), without which a box cannot read a board.
ENV MIX_ENV=prod ARKAB_UART=1 LANG=C.UTF-8 ERL_FLAGS="+S 12:12" MAKEFLAGS=-j8
RUN mix local.hex --force && mix local.rebar --force \
 && mix deps.get --only prod --check-locked \
 && mix compile \
 && mix release arkab --overwrite

# What the release must hold, as Arkab's own workflow checks it, and the C library it was built against.
RUN rel=/src/_build/prod/rel/arkab \
 && for needed in bin/arkab VERSION arkab.sh install.sh update.sh uninstall.sh arkab.service arkab-update.service arkab-update.path; do \
      [ -e "$rel/$needed" ] || { echo "the release has no $needed"; exit 1; }; done \
 && ls $rel/lib/circuits_uart-*/priv/circuits_uart \
 && ldd $rel/erts-*/bin/beam.smp \
 && getconf GNU_LIBC_VERSION \
 && cat $rel/VERSION \
 && mkdir /out && tar -czf /out/arkab-linux-aarch64.tar.gz -C /src/_build/prod/rel arkab
