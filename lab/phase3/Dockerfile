FROM oceanmail-mail-lab:phase2b

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends dovecot-imapd \
    && usermod -a -G mail bob \
    && rm -rf /var/lib/apt/lists/*

RUN test -x /usr/sbin/postfix \
    && test -x /usr/sbin/dovecot \
    && test -x /usr/sbin/sendmail \
    && id -nG bob | tr ' ' '\n' | grep -Fx mail

LABEL org.opencontainers.image.title="OceanMail Phase 3 standard mail-client lab" \
      org.opencontainers.image.description="Disposable Postfix SMTP + Dovecot IMAP compatibility station"

CMD ["/bin/bash"]
