# Builds the Alnasl release for aarch64 inside an arm64 container (qemu-user
# on the build VM). Debian 12 "bookworm" has glibc 2.36, the same as the
# Photon 5.0 image the release will run on; OpenSSL 3 and libtinfo.so.6 match
# too. OTP 29 + Elixir 1.20 as in Alnasl's CI.
FROM --platform=linux/arm64 hexpm/elixir:1.20.4-erlang-29.0.6-debian-bookworm-20261020-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY src/ /src/

ENV MIX_ENV=prod ALNASL_UART=1 LANG=C.UTF-8 ERL_FLAGS="+S 12:12" MAKEFLAGS=-j8
RUN mix local.hex --force && mix local.rebar --force \
 && mix deps.get --only prod --check-locked \
 && mix compile \
 && mix assets.deploy \
 && mix release alnasl --overwrite

RUN ls /src/_build/prod/rel/alnasl/lib/circuits_uart-*/priv/circuits_uart \
 && ldd /src/_build/prod/rel/alnasl/erts-*/bin/beam.smp \
 && getconf GNU_LIBC_VERSION \
 && mkdir /out && tar -czf /out/alnasl-linux-aarch64.tar.gz -C /src/_build/prod/rel alnasl
