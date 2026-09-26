FROM oceanmail-uucp-lab:phase1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends postfix \
    && rm -rf /var/lib/apt/lists/*

RUN id bob >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin bob \
    && id alice >/dev/null 2>&1 || useradd --create-home --shell /usr/sbin/nologin alice

RUN test -x /usr/sbin/postfix \
    && test -x /usr/sbin/postconf \
    && test -x /usr/sbin/sendmail \
    && test -x /usr/sbin/rmail \
    && test -x /usr/sbin/postqueue \
    && test -x /usr/bin/uux \
    && test -x /usr/sbin/uucico \
    && test -x /usr/local/bin/uucpd \
    && test -x /usr/local/bin/uuport

LABEL org.opencontainers.image.title="OceanMail Phase 2 RFC mail lab station" \
      org.opencontainers.image.description="Disposable Postfix + Taylor UUCP + HERMES uucpd/uuport station for RFC text-mail acceptance" \
      org.opencontainers.image.source="https://github.com/OceanMail/oceanmail-station"

CMD ["/bin/bash"]
