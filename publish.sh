#!/usr/bin/env bash
# 构建并发布多平台 Caddy（含 7 个插件）到 Docker Hub
#
#   ./publish.sh                    # 用 Dockerfile 里的 CADDY_VERSION
#   ./publish.sh 2.12.0             # 指定版本
#   REPO=foo/bar ./publish.sh 2.12.0
#   PLAT_LIST="linux/amd64 linux/arm64" ./publish.sh 2.12.0   # 自定义平台
#
# 为什么不用 buildx --push：本机 buildkit 导出器对大层有 60s 硬超时，
# 上行带宽低时必然失败（层已传完，卡在最后的 manifest PUT）。
# 所以先导出 OCI 归档，再用 skopeo（无硬超时、可重试）走代理推送。
set -euo pipefail

VER="${1:-}"
REPO="${REPO:-yyong201/caddy2-alpine}"
PROXY="${PROXY:-http://127.0.0.1:18080}"
PLAT_LIST="${PLAT_LIST:-linux/amd64 linux/arm64 linux/arm/v7}"
PLATFORMS="${PLAT_LIST// /,}"
AUTHFILE="${HOME}/.docker/config.json"
WORK="/home/dietpi/caddy-build"

cd "${WORK}"

if [ -z "${VER}" ]; then
  VER=$(grep -oE 'ARG CADDY_VERSION=[0-9.]+' Dockerfile | head -1 | cut -d= -f2)
fi
OUT="${WORK}/caddy-${VER}-multiarch.tar"

echo ">>> 目标: ${REPO}:v${VER} + latest   平台: ${PLATFORMS}"

echo ">>> 预拉基础镜像（避免 buildkit 解析 manifest 超时）"
docker pull "caddy:${VER}" >/dev/null
docker pull "caddy:${VER}-builder" >/dev/null
for P in ${PLAT_LIST}; do
  if ! docker pull --platform "${P}" "caddy:${VER}" >/dev/null 2>&1; then
    echo "!! caddy:${VER} 没有 ${P} 变体，请从 PLAT_LIST 中移除该平台后重试"
    exit 1
  fi
  echo "    ${P} OK"
done

echo ">>> 构建（首次全量编译约 15~25 分钟，命中缓存则几分钟）"
docker buildx build --builder rootless \
  --platform "${PLATFORMS}" \
  --provenance=false \
  --build-arg CADDY_VERSION="${VER}" \
  --output "type=oci,dest=${OUT}" .

echo ">>> 导出完成: $(du -h "${OUT}" | cut -f1)"

export HTTPS_PROXY="${PROXY}" HTTP_PROXY="${PROXY}"
export NO_PROXY="localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"

for TAG in "v${VER}" latest; do
  echo ">>> 推送 ${REPO}:${TAG}"
  skopeo copy --all --retry-times 5 --dest-authfile "${AUTHFILE}" \
    "oci-archive:${OUT}" "docker://${REPO}:${TAG}"
done

echo ">>> 校验远端"
skopeo inspect --raw "docker://${REPO}:v${VER}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("mediaType:", d.get("mediaType"))
for m in d.get("manifests",[]):
    p=m["platform"]
    v=("/"+p["variant"]) if p.get("variant") else ""
    print(" -", p["os"]+"/"+p["architecture"]+v, m["digest"][:20])
'
echo ">>> 全部完成"
