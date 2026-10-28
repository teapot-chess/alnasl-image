# Builds the Nunki release for aarch64 inside an arm64 container (qemu-user on the build VM), the way
# arkab/Dockerfile does for Arkab. Debian 12 "bookworm": glibc 2.36, the same as Photon 5.0; Nunki's
# install.sh wants 2.35 or newer. OTP 29 + Elixir 1.20 as in its CI. The source is `git archive` of the
# Nunki repo's HEAD (build.ps1), so the image ships exactly what is on main.
# Nunki has JavaScript of its own (esbuild): mix assets.deploy after compile, because the colocated hooks
# come out of the compiler (as in its own release workflow).
FROM --platform=linux/arm64 hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY src/ /src/

ENV MIX_ENV=prod LANG=C.UTF-8 ERL_FLAGS="+S 12:12" MAKEFLAGS=-j8
RUN mix local.hex --force && mix local.rebar --force \
 && mix deps.get --only prod --check-locked \
 && mix compile \
 && mix assets.deploy \
 && mix release nunki --overwrite

# What the release must hold (the Linux extras of mix.exs), and the C library it was built against.
RUN rel=/src/_build/prod/rel/nunki \
 && for needed in bin/nunki VERSION nunki.sh install.sh update.sh uninstall.sh nunki.service nunki-update.service nunki-update.path; do \
      [ -e "$rel/$needed" ] || { echo "the release has no $needed"; exit 1; }; done \
 && ldd $rel/erts-*/bin/beam.smp \
 && getconf GNU_LIBC_VERSION \
 && cat $rel/VERSION \
 && mkdir /out && tar -czf /out/nunki-linux-aarch64.tar.gz -C /src/_build/prod/rel nunki
