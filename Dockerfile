ARG CADDY_VERSION=2.11.9
ARG GOPROXY=https://goproxy.cn,direct

# ---------- build stage: runs natively on BUILDPLATFORM, cross-compiles to TARGETARCH ----------
FROM --platform=$BUILDPLATFORM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_VERSION
ARG GOPROXY
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ENV GOPROXY=${GOPROXY}
WORKDIR /src

RUN GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH} \
    GOARM=${TARGETVARIANT#v} \
    CGO_ENABLED=0 \
    GOFLAGS=-trimpath \
    xcaddy build "v${CADDY_VERSION}" \
      --output /usr/bin/caddy \
      --with github.com/caddy-dns/cloudflare \
      --with github.com/caddy-dns/tencentcloud \
      --with github.com/caddy-dns/alidns \
      --with github.com/caddyserver/forwardproxy \
      --with github.com/greenpau/caddy-security \
      --with github.com/mholt/caddy-webdav \
      --with github.com/mholt/caddy-l4

# ---------- runtime stage ----------
FROM caddy:${CADDY_VERSION}

ARG CADDY_VERSION
LABEL org.opencontainers.image.title="caddy-plugins" \
      org.opencontainers.image.description="Caddy ${CADDY_VERSION} + dns.providers {cloudflare,tencentcloud,alidns} + forwardproxy + security + webdav + layer4" \
      org.opencontainers.image.version="${CADDY_VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/caddy:${CADDY_VERSION}" \
      org.opencontainers.image.source="https://github.com/caddyserver/caddy"

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

