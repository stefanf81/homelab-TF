# syntax=docker/dockerfile:1.29

ARG CADDY_VERSION=2.11.9
# renovate: datasource=go depName=github.com/corazawaf/coraza-caddy/v2
ARG CORAZA_CADDY_VERSION=v2.6.2
# github.com/mholt/caddy-ratelimit has no tagged release with ipv4_prefix/
# ipv6_prefix, disable_metrics, or the metrics re-registration fix, so it is
# pinned to an immutable commit (post-dates the Caddy 2.11.4 release). Not
# tracked by Renovate on purpose: following its default branch would propose
# (and could automerge) every upstream commit; move it by hand after review.
ARG RATE_LIMIT_VERSION=5625512f24f6f59d6f64fb3aafe5eecff0b286db
# golang.org/x/net is raised above what Caddy 2.11.9 and the plugins require:
# their v0.60.0 has CVE-2026-78661 (HIGH, x/net/html, fixed in v0.62.0), which
# the build workflow's Trivy gate rejects. Drop the replace once a Caddy release
# requires this version or newer itself.
# renovate: datasource=go depName=golang.org/x/net
ARG XNET_VERSION=v0.63.0
ARG IMAGE_REVISION=r14

FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

ARG CORAZA_CADDY_VERSION
ARG RATE_LIMIT_VERSION
ARG XNET_VERSION

# The builder image sets XCADDY_SETCAP=1, so xcaddy would put
# cap_net_bind_service=+ep on the binary, and COPY carries that xattr into the
# runtime image. A pod with allowPrivilegeEscalation: false cannot exec such a
# binary ("operation not permitted"). The WAF listens on 8080 and needs no
# capability, so none is set; the check fails the build if one appears anyway.
# (Stripping it afterwards with `setcap -r` rewrote the whole binary into a
# second 57 MB layer.)
ENV XCADDY_SETCAP=0

RUN xcaddy build \
    --with github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION} \
    --with github.com/mholt/caddy-ratelimit@${RATE_LIMIT_VERSION} \
    --replace golang.org/x/net=golang.org/x/net@${XNET_VERSION} \
    && test -z "$(getcap /usr/bin/caddy)"

# Caddy's data and config directories (XDG_DATA_HOME / XDG_CONFIG_HOME below).
# The runtime image has no shell to create them, so they are staged here and
# copied with their ownership. The Deployments mount emptyDirs over both.
RUN mkdir -p /rootfs/data/caddy /rootfs/config/caddy

# Caddy is a static binary (xcaddy builds with CGO_ENABLED=0), so the runtime is
# distroless/static: CA certificates, tzdata, /etc/passwd and /etc/mime.types,
# but no shell, package manager, libc or curl. The caddy:<version>-alpine image
# used before also kept its own stock Caddy binary in a lower layer. Debug with
# `kubectl debug` (ephemeral container); `kubectl exec ... -- caddy <command>`
# still works.
# Pinned by digest: Renovate updates the digest when the nonroot tag moves (and
# bumps IMAGE_REVISION). Distroless only updates the current Debian line, so
# move to the next -debianNN by hand when it ships.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931

COPY --link --from=builder /usr/bin/caddy /usr/bin/caddy
COPY --link --from=builder --chown=65532:65532 /rootfs/ /

# Set by the official Caddy image; kept so Caddy uses /config and /data.
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

# distroless "nonroot". Numeric, so runAsNonRoot can verify it; the WAF
# Deployments set the same UID/GID.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
