FROM debian:trixie

ARG MERCURY_TAG=
ARG MERCURY_SHA=638193b9a9cc5ab15f272805af116e94b2fdf4c6

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       git \
       pkg-config \
       libasound2-dev \
       libpulse-dev \
       libhamlib-dev \
       libssl-dev \
       pulseaudio \
       pulseaudio-utils \
       python3 \
       procps \
       psmisc \
       util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/Rhizomatica/mercury.git /opt/mercury \
    && cd /opt/mercury \
    && git fetch --tags --prune origin \
    && if [ -n "$MERCURY_TAG" ]; then test "$(git rev-parse "refs/tags/${MERCURY_TAG}^{commit}")" = "$MERCURY_SHA"; fi \
    && git checkout --detach "$MERCURY_SHA" \
    && test "$(git rev-parse HEAD)" = "$MERCURY_SHA" \
    && make -j"$(nproc)" \
    && make test \
    && make -C utils/loopsim \
    && printf '%s\n' "$MERCURY_TAG" > /opt/mercury/.oceanmail-tag \
    && printf '%s\n' "$MERCURY_SHA" > /opt/mercury/.oceanmail-sha

COPY scripts/phase4i-mercury-container-entrypoint.sh /usr/local/bin/oceanmail-mercury-loop
RUN chmod 0755 /usr/local/bin/oceanmail-mercury-loop \
    && useradd --create-home --shell /bin/bash mercury

USER mercury
WORKDIR /opt/mercury
ENTRYPOINT ["/usr/local/bin/oceanmail-mercury-loop"]
