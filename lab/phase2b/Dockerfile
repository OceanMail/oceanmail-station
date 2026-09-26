FROM debian:trixie-slim AS uuxcomp-builder

ARG HERMES_NET_SHA=0fee4a53f54074ad6237b9fa1083a272cac89f60

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates git file \
       libb64-dev liblzma-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/Rhizomatica/hermes-net.git /src/hermes-net \
    && cd /src/hermes-net \
    && git checkout --detach "$HERMES_NET_SHA" \
    && test "$HERMES_NET_SHA" = 0fee4a53f54074ad6237b9fa1083a272cac89f60 \
    && test "$(git rev-parse HEAD)" = "$HERMES_NET_SHA" \
    && make -C uuxcomp \
    && bash uuxcomp/tests/run_tests.sh \
    && install -m 0755 uuxcomp/uuxcomp /out-uuxcomp \
    && install -m 0755 uuxcomp/crmail /out-crmail \
    && install -m 0755 system_scripts/email/mail_size_enforcement.sh /out-mail-size-enforcement

FROM oceanmail-mail-lab:phase2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends libb64-0d liblzma5 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uuxcomp-builder /out-uuxcomp /usr/local/bin/uuxcomp
COPY --from=uuxcomp-builder /out-crmail /usr/local/bin/crmail
COPY --from=uuxcomp-builder /out-mail-size-enforcement /usr/local/bin/mail_size_enforcement.sh

RUN ldconfig \
    && test -x /usr/local/bin/uuxcomp \
    && test -x /usr/local/bin/crmail \
    && test -x /usr/local/bin/mail_size_enforcement.sh \
    && ldd /usr/local/bin/uuxcomp \
    && ldd /usr/local/bin/crmail

LABEL org.opencontainers.image.title="OceanMail Phase 2B HERMES mail compression lab" \
      org.opencontainers.image.description="Disposable Postfix + HERMES uuxcomp/crmail + Taylor UUCP + Mercury station image"

CMD ["/bin/bash"]
