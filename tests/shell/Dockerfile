# Shell test image: the BusyBox 1.25 applets that the RT-AX86U has, plus jq
# and openssl from Alpine (the router has both). Used by tests/shell/run.sh
# and tools/check-sh.sh. busybox:1.25 exists only for amd64.
FROM --platform=linux/amd64 busybox:1.25 AS bb
FROM --platform=linux/amd64 alpine:3.20
RUN apk add --no-cache jq openssl
COPY --from=bb /bin/busybox /opt/bb125/busybox
COPY router-applets.txt /opt/bb125/applets.txt
RUN mkdir -p /opt/bb125/bin /opt/tools/bin \
 && have=" $(/opt/bb125/busybox --list | tr '\n' ' ') " \
 && for a in $(cat /opt/bb125/applets.txt); do \
      case "$have" in *" $a "*) ln -s ../busybox "/opt/bb125/bin/$a" ;; esac; \
    done \
 && ln -s /usr/bin/jq /opt/tools/bin/jq \
 && ln -s /usr/bin/openssl /opt/tools/bin/openssl \
 && ln -sf /opt/bb125/busybox /bin/sh
ENV PATH=/opt/bb125/bin:/opt/tools/bin
