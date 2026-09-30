# Caddy with the Cloudflare DNS module, so it can get a wildcard certificate by
# DNS challenge -- no public port, since everything it serves is tailnet-only.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
