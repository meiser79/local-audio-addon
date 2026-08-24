# The player lives upstream and is built here from a pinned ref; this repo never
# forks it. Bump both ARGs together: the SHA is checked against the clone, so a
# repointed tag fails the build instead of quietly shipping different code.
ARG SENDSPIN_CLI_REF=v0.1.1
ARG SENDSPIN_CLI_SHA=897e66a66501e3660d304250c779a29c318cf19d

# ghcr.io/home-assistant/amd64-base-debian:trixie, which ships s6-overlay v3 and
# bashio. CI overrides this with the digest for the architecture it is building;
# those per-arch digests live in .github/workflows/build.yml and release.yml, and
# a bump must move all three files together, staying on one Debian release.
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian@sha256:9281ee991c28532ddae10114ac84750f4aca287a496f6e19583f3a750ad5e786

# debian:trixie-slim, by multi-arch index digest rather than a per-architecture
# one, so that a cross-build resolves this stage to the target's architecture.
# Must stay on the same release as BUILD_FROM above: the binary built here is
# linked against that image's libc.
FROM debian@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258 AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG SENDSPIN_CLI_REF
ARG SENDSPIN_CLI_SHA

# PortAudio is deliberately absent: ALSA is the only backend this image offers.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libasound2-dev \
        libavahi-compat-libdnssd-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch "${SENDSPIN_CLI_REF}" \
        https://github.com/Sendspin/sendspin-cpp-cli.git . \
    && cloned="$(git rev-parse --verify HEAD)" \
    && if [ "${cloned}" != "${SENDSPIN_CLI_SHA}" ]; then \
        echo "sendspin-cli ${SENDSPIN_CLI_REF} is ${cloned}, expected ${SENDSPIN_CLI_SHA}" >&2; \
        exit 1; \
    fi

# A missing -dev dependency does not fail the configure step, it drops the
# backend and carries on, so these two greps on the configure summary are the
# only thing that catches the loss.
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DSENDSPIN_CLI_WITH_MDNS=ON \
        -DSENDSPIN_CLI_WITH_PORTAUDIO=OFF \
        -DSENDSPIN_CLI_BUILD_TESTS=OFF \
        | tee configure.log \
    && grep -qE '^-- sendspin-cli audio backends: null, stdout, alsa$' configure.log \
    && grep -qE '^-- sendspin-cli mDNS: dns_sd \(.*libdns_sd\.so.*\)$' configure.log

RUN cmake --build build -j"$(nproc)"

RUN DESTDIR=/stage cmake --install build --component sendspin-cli

# SENDSPIN_GIT_TAG is the Sendspin/sendspin-cpp tag upstream's CMake pulls in via
# FetchContent, so it is the transitive pin this image inherits.
RUN core_tag="$(sed -n 's/^set(SENDSPIN_GIT_TAG "\([^"]*\)".*/\1/p' CMakeLists.txt)" \
    && test -n "${core_tag}" \
    && printf 'SENDSPIN_CLI_REF=%s\nSENDSPIN_CLI_SHA=%s\nSENDSPIN_GIT_TAG=%s\n' \
        "${SENDSPIN_CLI_REF}" "${SENDSPIN_CLI_SHA}" "${core_tag}" \
        > /build-info.txt


FROM ${BUILD_FROM}

ARG SENDSPIN_CLI_REF

LABEL \
    org.opencontainers.image.source="https://github.com/music-assistant/local-audio-addon" \
    org.opencontainers.image.version="${SENDSPIN_CLI_REF}" \
    org.opencontainers.image.licenses="Apache-2.0"

# libasound2-plugins carries the ALSA-to-Pulse bridge, which is what makes the
# `default` output work on Home Assistant OS, where /etc/asound.conf routes
# `default` to Home Assistant's PulseAudio. libstdc++6 is already present in any
# image with apt, but the player links it, so it is named rather than inherited.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        avahi-daemon \
        dbus \
        libasound2-plugins \
        libasound2t64 \
        libavahi-compat-libdnssd1 \
        libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# The base image sets this too, but the s6-overlay default is to carry on: the
# sendspin-init oneshot reports a Supervisor it cannot reach by failing, and
# that has to stop the container rather than leave the services to flounder.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

# The Supervisor stops an add-on with the grace its `timeout` option asks for and
# calls a container that overruns it a failure. That option defaults to 10s and
# config.yaml does not set it, so the shutdown needs a budget it cannot exceed.
# Raising `timeout` instead would buy silence rather than a clean stop, and the
# add-on would still be sitting there not shutting down.
#
# The three longruns come down in sequence, each bounded by its own
# `timeout-kill` of 2000ms, and this is what bounds the tail after them: 3 * 2000
# + 2000 = 8s worst case, measured at 8.2s with all three deliberately wedged.
#
# The other two gracetimes s6-overlay documents are deliberately absent. They
# look relevant and are not: S6_SERVICES_GRACETIME only bounds the v2-style
# services under /etc/services.d, and S6_KILL_FINISH_MAXTIME only bounds
# /etc/cont-finish.d scripts. This image ships neither directory.
ENV S6_KILL_GRACETIME=2000

COPY --from=build /stage/usr/local/bin/sendspin-cli /usr/bin/sendspin-cli
COPY --from=build /build-info.txt /usr/share/sendspin-cli/BUILD-INFO.txt
COPY rootfs/ /

# No ENTRYPOINT or CMD: the base image's /init runs s6, which starts the
# services in rootfs/etc/s6-overlay.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/usr/bin/container-healthcheck"]
