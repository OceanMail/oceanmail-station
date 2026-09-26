FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && printf '%s\n' \
       'postfix postfix/mailname string stationa.test' \
       'postfix postfix/main_mailer_type select Local only' \
       | debconf-set-selections \
    && apt-get install -y --no-install-recommends \
       postfix \
       ca-certificates \
       procps \
    && rm -rf /var/lib/apt/lists/*

RUN cat > /usr/local/bin/phase4b-tempfail <<'EOF'
#!/bin/sh
cat >/dev/null
exit 75
EOF
RUN chmod 0755 /usr/local/bin/phase4b-tempfail \
    && test -x /usr/sbin/postfix \
    && test -x /usr/sbin/postqueue \
    && test -x /usr/sbin/sendmail \
    && test -x /usr/sbin/postsuper \
    && test -x /usr/bin/pgrep

LABEL org.opencontainers.image.title="OceanMail Phase 4B real Postfix queue lab" \
      org.opencontainers.image.description="Disposable Postfix instance with deterministic temporary-failure transport for Station queue observation"

CMD ["sleep", "infinity"]
