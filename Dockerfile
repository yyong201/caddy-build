ARG CADDY_VERSION=2.11.9
ARG GOPROXY=https://goproxy.cn,direct
# 可选：钉住 caddy-security 版本。留空 = 取最新。
# CI 与 caddy-multiarch-kit.sh 按基础 caddy 版本自动按区间钉版：
#   2.11.4 ~ 2.11.6  -> v1.3.0（其 go.mod 要求 caddy >= 2.11.4）
#   2.11.7 ~ 2.11.x  -> v1.6.2（其 go.mod 要求 caddy >= 2.11.7）
#   >= 2.12.0        -> 不钉，取最新
# 背景：caddy-security v1.4.0+ 把最低要求提到 caddy >= 2.11.7，不钉会在 go get 阶段报
#   github.com/greenpau/caddy-security@v1.6.2 requires caddy/v2@v2.11.7, but v2.11.6 is requested
ARG SECURITY_VERSION=
# 可选：钉 caddy-l4 版本（留空 = 最新）。2.11.1~2.11.3 需要钉旧版：
#   2.11.3 -> v0.1.1；2.11.2/2.11.1 -> v0.1.0；>=2.11.4 用最新 v0.1.2
ARG L4_VERSION=

# ---------- 构建阶段：跑在宿主原生架构上，交叉编译到 TARGETARCH ----------
FROM --platform=$BUILDPLATFORM caddy:${CADDY_VERSION}-builder AS builder

ARG CADDY_VERSION
ARG GOPROXY
ARG SECURITY_VERSION
ARG L4_VERSION
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
      --with github.com/mholt/caddy-l4${L4_VERSION:+@${L4_VERSION}}

# ---------- 运行阶段：只 COPY，不执行目标架构二进制（无 QEMU 也可构建） ----------
FROM caddy:${CADDY_VERSION}

ARG CADDY_VERSION
LABEL org.opencontainers.image.title="caddy-plugins" \
      org.opencontainers.image.description="Caddy ${CADDY_VERSION} + dns.providers {cloudflare,tencentcloud,alidns} + forwardproxy + security + webdav + layer4" \
      org.opencontainers.image.version="${CADDY_VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/caddy:${CADDY_VERSION}" \
      org.opencontainers.image.source="https://github.com/caddyserver/caddy"

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
