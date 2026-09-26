FROM debian:trixie AS builder

ARG HERMES_NET_SHA=0fee4a53f54074ad6237b9fa1083a272cac89f60

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       git \
    && rm -rf /var/lib/apt/lists/*

COPY lab/phase1/hermes-vara-discard-stale-data.patch /tmp/hermes-vara-discard-stale-data.patch

RUN git clone https://github.com/Rhizomatica/hermes-net.git /src/hermes-net \
    && cd /src/hermes-net \
    && git checkout --detach "$HERMES_NET_SHA" \
    && test "$HERMES_NET_SHA" = 0fee4a53f54074ad6237b9fa1083a272cac89f60 \
    && test "$(git rev-parse HEAD)" = "$HERMES_NET_SHA" \
    && git apply --check /tmp/hermes-vara-discard-stale-data.patch \
    && git apply /tmp/hermes-vara-discard-stale-data.patch \
    && make -C uucpd clean \
    && make -C uucpd \
    && test -x uucpd/uucpd \
    && test -x uucpd/uuport

FROM debian:trixie

ARG HERMES_NET_SHA=0fee4a53f54074ad6237b9fa1083a272cac89f60

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       ca-certificates \
       iproute2 \
       procps \
       psmisc \
       uucp \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/hermes-net/uucpd/uucpd /usr/local/bin/uucpd
COPY --from=builder /src/hermes-net/uucpd/uuport /usr/local/bin/uuport
COPY --from=builder /src/hermes-net/uucpd/LICENSE /usr/local/share/licenses/hermes-uucpd/LICENSE
COPY lab/phase1/hermes-vara-discard-stale-data.patch /usr/local/share/oceanmail/hermes-vara-discard-stale-data.patch
COPY lab/phase1/HERMES_PATCH_NOTICE.md /usr/local/share/oceanmail/HERMES_PATCH_NOTICE.md

RUN mkdir -p /usr/local/share/oceanmail \
    && printf '%s\n' "$HERMES_NET_SHA" > /usr/local/share/oceanmail/hermes-net.sha \
    && sha256sum /usr/local/share/oceanmail/hermes-vara-discard-stale-data.patch \
       > /usr/local/share/oceanmail/hermes-vara-discard-stale-data.patch.sha256 \
    && test -x /usr/sbin/uucico \
    && test -x /usr/bin/uucp \
    && test -x /usr/local/bin/uucpd \
    && test -x /usr/local/bin/uuport \
    && test -x /usr/bin/killall

LABEL org.opencontainers.image.title="OceanMail Phase 1 UUCP lab station" \
      org.opencontainers.image.description="Disposable Debian 13 lab image with Taylor UUCP and pinned HERMES uucpd/uuport plus tracked stale-session data patch" \
      org.opencontainers.image.source="https://github.com/OceanMail/oceanmail-station"

CMD ["/bin/bash"]
