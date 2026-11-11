#!/usr/bin/env bash
# =============================================================================
# caddy-multiarch-kit.sh — 一键构建并发布多平台 Caddy（含 7 个插件）
#
#   单文件自包含：内置 Dockerfile，不依赖同目录其他文件。
#   在任意 amd64 Linux 上（需 docker + buildx）：
#
#     bash caddy-multiarch-kit.sh            # 默认 2.11.9
#     bash caddy-multiarch-kit.sh 2.12.0     # 指定版本
#
#   常用环境变量：
#     REPO=yyong201/caddy2-alpine     目标仓库
#     PLAT_LIST="linux/amd64 linux/arm64 linux/arm/v7"
#     PROXY=http://127.0.0.1:18080    走代理（直连机器留空）
#     GOPROXY_MIRROR=https://goproxy.cn,direct   构建阶段 Go 模块代理
#     BUILDER=rootless | caddy-multi  指定 buildx builder（默认自动探测）
#     PUSH=0                          只构建不推送
#     TAGS="v2.11.9 latest"           推送的标签
#     WORK=$HOME/caddy-build          工作目录（Dockerfile 落在这里）
#     DRY_RUN=1                       只做环境检查并打印计划
#
#   设计说明（为什么要两步走，而不是 buildx --push）：
#     部分机器上行带宽低，buildkit 导出器推大层有 ~60s 硬超时，
#     会稳定报 failed to authorize: DeadlineExceeded（层其实已传完）。
#     因此改为：buildx 出 OCI 归档 -> skopeo 走标准 HTTP(S) 代理推送，
#     skopeo 无该硬超时且可重试。直连机器上也同样可用。
#
#   为什么不需要 QEMU/binfmt：
#     构建阶段用 FROM --platform=$BUILDPLATFORM，builder 原生跑在宿主架构，
#     靠 GOOS/GOARCH/GOARM + CGO_ENABLED=0 交叉编译出目标架构的静态二进制；
#     末阶段只有 COPY，不执行目标架构二进制。
# =============================================================================
set -euo pipefail

VER="${1:-2.11.9}"
REPO="${REPO:-yyong201/caddy2-alpine}"
WORK="${WORK:-$HOME/caddy-build}"
PLAT_LIST="${PLAT_LIST:-linux/amd64 linux/arm64 linux/arm/v7}"
PLATFORMS="${PLAT_LIST// /,}"
PROXY="${PROXY:-}"
GOPROXY_MIRROR="${GOPROXY_MIRROR:-https://goproxy.cn,direct}"
BUILDER="${BUILDER:-}"
PUSH="${PUSH:-1}"
TAGS="${TAGS:-v${VER} latest}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$PROXY" ] && { export HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"; \
  export NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12}"; }

# ---------------------------------------------------------------- 0. 环境检查
log "检查运行环境"
command -v docker >/dev/null || die "未安装 docker"
docker info >/dev/null 2>&1 || die "docker daemon 不可用（未启动或当前用户无权限）"
docker buildx version >/dev/null 2>&1 || die "缺少 buildx 插件（docker buildx install）"
command -v python3 >/dev/null || warn "没有 python3，最后的远端校验会跳过"
echo "    docker : $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
echo "    buildx : $(docker buildx version | awk '{print $2}')"
echo "    宿主架构: $(uname -m)"

# ---------------------------------------------------------------- 1. skopeo
if ! command -v skopeo >/dev/null; then
  log "未找到 skopeo，尝试自动安装"
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die "需要 root 或 sudo 来安装 skopeo"
    SUDO="sudo"
  fi
  if command -v apt-get >/dev/null; then
    $SUDO apt-get update -qq && $SUDO apt-get install -y skopeo
  elif command -v dnf >/dev/null; then $SUDO dnf install -y skopeo
  elif command -v yum >/dev/null; then $SUDO yum install -y skopeo
  elif command -v apk >/dev/null; then $SUDO apk add --no-cache skopeo
  elif command -v pacman >/dev/null; then $SUDO pacman -Sy --noconfirm skopeo
  elif command -v zypper >/dev/null; then $SUDO zypper -n install skopeo
  else die "未识别的包管理器，请手动安装 skopeo 后重跑"
  fi
fi
echo "    skopeo : $(skopeo --version 2>&1 | head -1)"

# ---------------------------------------------------------------- 2. builder
if [ -z "$BUILDER" ]; then
  if docker buildx inspect rootless >/dev/null 2>&1; then BUILDER="rootless"
  elif docker buildx inspect default >/dev/null 2>&1; then BUILDER="default"
  else BUILDER="caddy-multi"; fi
fi
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  log "创建 buildx builder: $BUILDER (docker-container)"
  docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
fi
log "准备 builder: $BUILDER"
docker buildx inspect --bootstrap "$BUILDER" >/dev/null
echo "    平台能力: $(docker buildx inspect "$BUILDER" | grep -i '^Platforms' | cut -c1-160)"

# 预拉基础镜像：避免 buildkit 解析远端 manifest 超时，并提前发现缺架构
log "预拉基础镜像 caddy:${VER} / caddy:${VER}-builder"
docker pull "caddy:${VER}"         >/dev/null
docker pull "caddy:${VER}-builder" >/dev/null
for P in $PLAT_LIST; do
  docker pull --platform "$P" "caddy:${VER}" >/dev/null 2>&1 \
    || die "caddy:${VER} 没有 ${P} 变体，请调整 PLAT_LIST 后重跑"
  echo "    ${P} OK"
done

# ---------------------------------------------------------------- 3. 工作目录
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f Dockerfile ]; then
  log "写入内置 Dockerfile 到 $WORK/Dockerfile"
  cat > Dockerfile <<'DOCKERFILE'
ARG CADDY_VERSION=2.11.9
ARG GOPROXY=https://goproxy.cn,direct
# 钉插件版本（留空=最新）。caddy-security v1.4.0+ 要求 caddy >= 2.11.7，
# 因此构建 2.11.4/5/6 时脚本会自动填 v1.3.0。
ARG SECURITY_VERSION=

# 构建阶段：跑在宿主原生架构上，交叉编译到 TARGETARCH
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
      --with github.com/greenpau/caddy-security${SECURITY_VERSION:+@${SECURITY_VERSION}} \
      --with github.com/mholt/caddy-webdav \
      --with github.com/mholt/caddy-l4

# 运行阶段：只 COPY，不执行目标架构二进制（无 QEMU 也可构建）
FROM caddy:${CADDY_VERSION}

ARG CADDY_VERSION
LABEL org.opencontainers.image.title="caddy-plugins" \
      org.opencontainers.image.description="Caddy ${CADDY_VERSION} + dns.providers {cloudflare,tencentcloud,alidns} + forwardproxy + security + webdav + layer4" \
      org.opencontainers.image.version="${CADDY_VERSION}" \
      org.opencontainers.image.base.name="docker.io/library/caddy:${CADDY_VERSION}" \
      org.opencontainers.image.source="https://github.com/caddyserver/caddy"

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
DOCKERFILE
else
  log "复用已存在的 $WORK/Dockerfile"
fi

OUT="$WORK/caddy-${VER}-multiarch.tar"

# caddy-security v1.4.0+ 要求 caddy >= 2.11.7；低于该版本时自动钉 v1.3.0（要求 >= 2.11.4）
SECURITY_VERSION="${SECURITY_VERSION:-}"
LOWEST=$( { echo 2.11.7; echo "${VER}"; } | sort -V | head -1 )
if [ "${LOWEST}" = "${VER}" ] && [ "${VER}" != "2.11.7" ]; then
  SECURITY_VERSION=v1.3.0
  log "caddy ${VER} < 2.11.7 -> auto pin caddy-security@${SECURITY_VERSION}"
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN：以下命令将执行（未真正运行）"
  echo "docker buildx build --builder $BUILDER \\"
  echo "  --platform $PLATFORMS --provenance=false \\"
  echo "  --build-arg CADDY_VERSION=$VER --build-arg GOPROXY=$GOPROXY_MIRROR \\"
  echo "  --output type=oci,dest=$OUT ."
  for T in $TAGS; do echo "skopeo copy --all --retry-times 5 oci-archive:$OUT docker://$REPO:$T"; done
  exit 0
fi

# ---------------------------------------------------------------- 4. 构建
log "开始构建 $REPO:v$VER  [$PLATFORMS]  （首次约 15~25 分钟）"
docker buildx build --builder "$BUILDER" \
  --platform "$PLATFORMS" \
  --provenance=false \
  --build-arg CADDY_VERSION="$VER" \
  --build-arg GOPROXY="$GOPROXY_MIRROR" \
  --build-arg SECURITY_VERSION="${SECURITY_VERSION}" \
  --output "type=oci,dest=$OUT" .
log "导出完成: $(du -h "$OUT" | cut -f1)  ->  $OUT"

if [ "$PUSH" != "1" ]; then
  log "PUSH=0，跳过推送。归档位置: $OUT"
  exit 0
fi

# ---------------------------------------------------------------- 5. 推送
AUTHFILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
[ -f "$AUTHFILE" ] || die "未找到 $AUTHFILE，请先 docker login"

for T in $TAGS; do
  log "推送 $REPO:$T"
  skopeo copy --all --retry-times 5 --dest-authfile "$AUTHFILE" \
    "oci-archive:$OUT" "docker://$REPO:$T"
done

# ---------------------------------------------------------------- 6. 校验
if command -v python3 >/dev/null; then
  log "校验远端 manifest list"
  skopeo inspect --raw "docker://$REPO:v$VER" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("  mediaType:", d.get("mediaType"))
for m in d.get("manifests",[]):
    p=m["platform"]; v=("/"+p["variant"]) if p.get("variant") else ""
    print("   -", p["os"]+"/"+p["architecture"]+v, m["digest"][:20])
'
fi

log "全部完成"
echo "  拉取：docker pull $REPO:v$VER"
echo "  指定架构：docker pull --platform linux/arm64 $REPO:v$VER"
echo "  清理归档：rm $OUT   （约 144MB/版本）"
