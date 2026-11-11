ARG CADDY_VERSION=2.11.9
ARG GOPROXY=https://goproxy.cn,direct
# 可选：钉住个别插件版本。留空 = 取最新。
# 为什么需要它：caddy-security v1.4.0+ 把最低要求提到 caddy >= 2.11.7，
# 所以构建 caddy 2.11.4/5/6 时必须钉 SECURITY_VERSION=v1.3.0（要求 >= 2.11.4），
# 否则 xcaddy 会在 go get 阶段报：
#   github.com/greenpau/caddy-security@v1.6.2 requires caddy/v2@v2.11.7, but v2.11.6 is requested
ARG SECURITY_VERSION=

# ---------- 构建阶段：跑在宿主原生架构上，交叉编译到 TARGETARCH ----------
FROM --platform=$BUILDPLATFORM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_VERSION
ARG GOPROXY
ARG SECURITY_VERSION
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
      --with github.com/greenpau/caddy-security${SECURITY_VERSION:+@$SECURITY_VERSION} \
      --with github.com/mholt/caddy-webdav \
      --with github.com/mholt/caddy-l4

# ---------- 运行阶段：只 COPY，不执行目标架构二进制（无 QEMU 也可构建） ----------
FROM caddy:${CADDY_VERSION}

ARG CADDY_VERSION
LABEL org.opencontainers.image.title="caddy-plugins" \
      org.opencontainers.image.description="Caddy ${CADDY_VERSION} + dns.providers {cloudflare,tencentcloud,alidns} + forwardproxy + security + webdav + layer4" \
      org.opencontainers.image.version="${CADDY_VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/caddy:${CADDY_VERSION}" \
      org.opencontainers.image.source="https://github.com/caddyserver/caddy"

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
