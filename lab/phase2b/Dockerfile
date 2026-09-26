FROM debian:trixie-slim AS uuxcomp-builder

ARG HERMES_NET_SHA=5c76adff754de49c0b934c7fd7bddf7619b0c3d6
ARG LIBCMIME_SHA=dd21eb096d162656e30243f60fc4bc35ad39ae6e

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential ca-certificates git cmake flex bison file libfl-dev \
       libb64-dev liblzma-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY lab/phase2b/libcmime-empty-sender.patch /tmp/libcmime-empty-sender.patch

RUN git clone https://github.com/spmfilter/libcmime.git /src/libcmime \
    && cd /src/libcmime \
    && git checkout "$LIBCMIME_SHA" \
    && test "$(git rev-parse HEAD)" = dd21eb096d162656e30243f60fc4bc35ad39ae6e \
    && git apply --check /tmp/libcmime-empty-sender.patch \
    && git apply /tmp/libcmime-empty-sender.patch \
    && cmake -S . -B build \
       -DPREFIX=/usr/local \
       -DFL_LIBRARY="$(gcc -print-file-name=libfl.so)" \
       -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
       -DCMAKE_C_FLAGS=-fPIC \
       -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    && cmake --build build -j"$(nproc)" \
    && mkdir -p /usr/local/lib /usr/local/include/cmime \
    && cp -a build/src/libcmime.so* /usr/local/lib/ \
    && cp src/cmime.h /usr/local/include/cmime.h \
    && cp src/*.h /usr/local/include/cmime/ \
    && test -e /usr/local/lib/libcmime.so \
    && test -e /usr/local/include/cmime.h \
    && test -e /usr/local/include/cmime/cmime_message.h \
    && ldconfig

RUN git clone https://github.com/Rhizomatica/hermes-net.git /src/hermes-net \
    && cd /src/hermes-net \
    && git checkout "$HERMES_NET_SHA" \
    && make -C uuxcomp \
       LDFLAGS='-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lb64 -llzma -lz -lcmime' \
    && install -m 0755 uuxcomp/uuxcomp /out-uuxcomp \
    && install -m 0755 uuxcomp/crmail /out-crmail \
    && install -m 0755 system_scripts/email/mail_size_enforcement.sh /out-mail-size-enforcement

FROM oceanmail-mail-lab:phase2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends libb64-0d liblzma5 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uuxcomp-builder /usr/local/lib/libcmime.so* /usr/local/lib/
COPY --from=uuxcomp-builder /src/libcmime/COPYING /usr/local/share/licenses/libcmime/COPYING
COPY lab/phase2b/libcmime-NOTICE /usr/local/share/licenses/libcmime/NOTICE
COPY --from=uuxcomp-builder /out-uuxcomp /usr/local/bin/uuxcomp
COPY --from=uuxcomp-builder /out-crmail /usr/local/bin/crmail
COPY --from=uuxcomp-builder /out-mail-size-enforcement /usr/local/bin/mail_size_enforcement.sh

RUN test -s /usr/local/share/licenses/libcmime/COPYING \
    && test -s /usr/local/share/licenses/libcmime/NOTICE \
    && ldconfig \
    && test -x /usr/local/bin/uuxcomp \
    && test -x /usr/local/bin/crmail \
    && test -x /usr/local/bin/mail_size_enforcement.sh \
    && ldd /usr/local/bin/uuxcomp \
    && ldd /usr/local/bin/crmail

LABEL org.opencontainers.image.title="OceanMail Phase 2B HERMES mail compression lab" \
      org.opencontainers.image.description="Disposable Postfix + HERMES uuxcomp/crmail + Taylor UUCP + Mercury station image"

CMD ["/bin/bash"]
