# syntax=docker/dockerfile:1.7

ARG CADDY_VERSION=2.11.4
ARG CORAZA_CADDY_VERSION=v2.5.0

FROM caddy:${CADDY_VERSION}-builder-alpine AS builder

ARG CORAZA_CADDY_VERSION

RUN xcaddy build \
    --with github.com/corazawaf/coraza-caddy/v2@${CORAZA_CADDY_VERSION}

FROM caddy:${CADDY_VERSION}-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

RUN addgroup -S caddy \
    && adduser -S -G caddy caddy \
    && chown -R caddy:caddy /data /config

USER caddy

EXPOSE 8080

ENTRYPOINT ["/usr/bin/caddy"]
CMD ["run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
