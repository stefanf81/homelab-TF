# syntax=docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183

# The Caddy version is the tag of the builder image below (its FROM line is the
# single place; the build workflow reads the image tag from it).
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
# OWASP CRS and Coraza's recommended base configuration ship as files under
# /usr/share/coraza and the WAF ConfigMaps Include them from there. They are
# NOT taken from the copy embedded in the connector (`load_owasp_crs`):
# coraza-caddy v2.6.2 embeds github.com/corazawaf/coraza-coreruleset/v4, which
# upstream froze at v4.25.0 (CRS 4.25.0 without the 4.25.1/4.25.2 bypass fixes,
# and a coraza.conf-recommended older than the Coraza 3.8 engine: it lacks
# rules 200004/200005, so arguments beyond SecArgumentsLimit were dropped
# silently instead of the request being rejected). Upstream now publishes one
# Go module per bundle; pinning them here also keeps a connector update from
# moving the rule set. Both are fetched with `go mod download`, i.e. through
# the Go module proxy and verified against the Go checksum database, like every
# module compiled into the binary.
# CRS: the 4.25 LTS line (security backports only, until Q3 2027). To follow
# the latest line instead, switch the module to .../crs/v4 here and in the
# RUN step below (its files are named @owasp_crs and @crs-setup.conf.example).
# renovate: datasource=go depName=github.com/corazawaf/coraza-coreruleset/lts/v4
ARG CRS_VERSION=v4.25.2
# Keep on the minor of the Coraza engine the connector compiles in (go.mod of
# coraza-caddy): the file may use directives a newer engine introduced.
# renovate: datasource=go depName=github.com/corazawaf/coraza-coreruleset/coraza/v3
ARG CORAZA_CONF_VERSION=v3.8.1
ARG IMAGE_REVISION=r14

# Tag and digest, like the runtime image below: the tag alone is rebuilt in
# place (new Go patch release, Alpine updates), so the same Dockerfile could
# produce a different binary. Written out instead of `caddy:${CADDY_VERSION}-…`
# because Renovate replaces version and digest together only when both are on
# this line; with the version in an ARG it could not move the tag.
FROM caddy:2.11.9-builder-alpine@sha256:646fee578e680989ca5c7fd1ce6f1de574d19fd71ef2221810cc0510a9f40c86 AS builder

ARG CORAZA_CADDY_VERSION
ARG RATE_LIMIT_VERSION
ARG XNET_VERSION
ARG CRS_VERSION
ARG CORAZA_CONF_VERSION

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

# Rule files (see the CRS_VERSION comment above). The @-prefixed names are the
# aliases of the embedded bundles; on disk they get plain names, and the .data
# files stay next to the rules that load them (@pmFromFile resolves relative to
# the including file). Staged in their own tree so they are copied root-owned:
# the WAF process (65532) can read but never rewrite its own rules. The two
# greps fail the build if upstream renames a file or the pins do not match.
RUN go mod download \
        "github.com/corazawaf/coraza-coreruleset/lts/v4@${CRS_VERSION}" \
        "github.com/corazawaf/coraza-coreruleset/coraza/v3@${CORAZA_CONF_VERSION}" \
    && src="$(go env GOMODCACHE)/github.com/corazawaf/coraza-coreruleset" \
    && dst=/rules/usr/share/coraza \
    && mkdir -p "$dst/crs" \
    && cp "$src/coraza/v3@${CORAZA_CONF_VERSION}/files/@coraza.conf-recommended" "$dst/coraza.conf-recommended" \
    && cp "$src/lts/v4@${CRS_VERSION}/rules/@crs-setup-lts.conf.example" "$dst/crs/crs-setup.conf.example" \
    && cp -r "$src/lts/v4@${CRS_VERSION}/rules/@owasp_crs_lts" "$dst/crs/rules" \
    && cp "$src/lts/v4@${CRS_VERSION}/rules/LICENSE" "$dst/crs/LICENSE" \
    && chmod -R u=rwX,go=rX "$dst" \
    && grep -q "OWASP_CRS/${CRS_VERSION#v}\"" "$dst/crs/rules/REQUEST-901-INITIALIZATION.conf" \
    && grep -q "id:'200004'" "$dst/coraza.conf-recommended"

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
COPY --link --from=builder /rules/ /

# Set by the official Caddy image; kept so Caddy uses /config and /data.
ENV XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/data

# distroless "nonroot". Numeric, so runAsNonRoot can verify it; the WAF
# Deployments set the same UID/GID.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
