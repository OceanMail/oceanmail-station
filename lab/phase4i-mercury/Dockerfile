FROM debian:trixie

ARG MERCURY_TAG=v1.9.13
ARG MERCURY_SHA=4eac25e06a0c88996621bc74af5b7b2f0d353848

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       git \
       pkg-config \
       libasound2-dev \
       libpulse-dev \
       libhamlib-dev \
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
    && test "$(git rev-parse "refs/tags/${MERCURY_TAG}^{commit}")" = "$MERCURY_SHA" \
    && git checkout --detach "$MERCURY_SHA" \
    && test "$(git rev-parse HEAD)" = "$MERCURY_SHA" \
    && make -j"$(nproc)" \
    && make -C utils/loopsim \
    && printf '%s\n' "$MERCURY_TAG" > /opt/mercury/.oceanmail-tag \
    && printf '%s\n' "$MERCURY_SHA" > /opt/mercury/.oceanmail-sha

COPY scripts/phase4i-mercury-container-entrypoint.sh /usr/local/bin/oceanmail-mercury-loop
RUN chmod 0755 /usr/local/bin/oceanmail-mercury-loop \
    && useradd --create-home --shell /bin/bash mercury

USER mercury
WORKDIR /opt/mercury
ENTRYPOINT ["/usr/local/bin/oceanmail-mercury-loop"]
