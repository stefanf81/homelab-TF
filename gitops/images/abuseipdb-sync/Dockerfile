# syntax=docker/dockerfile:1.29@sha256:572cebbc2b15e6f84c077742952674889cb63cd5e9b80abdffcbe587b6f19183

# Version inputs are parsed by .github/workflows/build-abuseipdb-sync.yaml to
# derive the image tag and the Go toolchain its tests run on. Keep the ARG
# format stable.
# GO_IMAGE holds the tag and the digest in one ARG so that Renovate rewrites
# both together. With the version in an ARG of its own and the digest on the
# FROM line, Renovate only replaces the digest, and a Go update would leave the
# old version next to the new image.
ARG GO_IMAGE=golang:1.27.4-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280
ARG APP_VERSION=0.3.5
ARG IMAGE_REVISION=r11

FROM ${GO_IMAGE} AS build
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG APP_VERSION
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags "-s -w -X main.version=${APP_VERSION}" \
    -o /out/abuseipdb-sync .

# Distroless only updates the current Debian line (debian12 builds stopped
# 2026-08-11). Pinned by digest, so a rebuild gets the same base; Renovate
# updates the digest when the nonroot tag moves (and bumps IMAGE_REVISION). It
# does not propose the next Debian line: move to -debianNN by hand when it ships.
FROM gcr.io/distroless/static-debian13:nonroot@sha256:8ce6dd87e9823c5b48dcfb2c8604714ccb351ce59607327bcc4957448da279b5
COPY --from=build /out/abuseipdb-sync /usr/local/bin/abuseipdb-sync
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/abuseipdb-sync"]
