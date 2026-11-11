# caddy-multiarch — Caddy 2 多平台镜像构建

构建带 **cloudflare / tencentcloud / alidns DNS + forwardproxy + caddy-security + webdav + l4** 七个插件的 Caddy 2 镜像，
一次产出 `linux/amd64`、`linux/arm64`、`linux/arm/v7` 三个平台，推送到 Docker Hub。

已发布：`yyong201/caddy2-alpine:v2.11.9` / `:latest`（2026-11-10 实测通过）

## 快速开始

```bash
# 本机（需要代理时）
PROXY=http://127.0.0.1:18080 bash caddy-multiarch-kit.sh 2.11.9

# 其他 amd64 机器：拷过去 → 登录 → 直接跑
scp caddy-multiarch-kit.sh user@host:~/
docker login -u 用户名
bash caddy-multiarch-kit.sh 2.12.0
```

`caddy-multiarch-kit.sh` 是**单文件自包含**的（内嵌 Dockerfile），不依赖同目录其他文件。

## 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `REPO` | `yyong201/caddy2-alpine` | 目标仓库 |
| `PLAT_LIST` | `linux/amd64 linux/arm64 linux/arm/v7` | 目标平台（空格分隔，会预检） |
| `PROXY` | 空 | 如 `http://127.0.0.1:18080` |
| `GOPROXY_MIRROR` | `https://goproxy.cn,direct` | 构建阶段 Go 模块代理 |
| `BUILDER` | 自动探测 | buildx builder 名 |
| `TAGS` | `v<ver> latest` | 推送标签 |
| `PUSH` | `1` | `0` = 只构建 |
| `WORK` | `~/caddy-build` | 工作目录 |
| `DRY_RUN` | `0` | `1` = 只检查并打印计划 |

## 四个关键设计决策

1. **不需要 QEMU/binfmt**：构建阶段 `FROM --platform=$BUILDPLATFORM`，靠 `GOOS/GOARCH/GOARM` + `CGO_ENABLED=0` 交叉编译；`buildx inspect` 只显示 amd64 属正常。
2. **运行阶段禁止写 `RUN`**：无模拟器执行目标架构二进制会 `exec format error`，只能 `COPY`。
3. **构建阶段必须设 `GOPROXY`**：`proxy.golang.org` 在国内不可达。
4. **本地不要用 `buildx --push`**：buildkit 导出器推大层有 ~60s 硬超时（上行带宽低时必失败）。改为
   `--output type=oci` 导出归档 + `skopeo copy` 推送（无硬超时、可重试）。CI 环境不适用此限制，见下文。

## CI 自动构建（GitHub Actions）

工作流：`.github/workflows/build-image.yml`

| 触发 | 行为 |
|---|---|
| 手动：Actions → `build-caddy-image` → Run workflow | 可填 Caddy 版本 / 平台 / 是否更新 `latest`；版本留空则取 `Dockerfile` 的 `ARG CADDY_VERSION` |
| 推标签：`git tag -a v2.12.0 -m "Caddy 2.12.0" && git push origin v2.12.0` | 自动构建 `2.12.0`，推 `v2.12.0` + `latest` |

CI 与本地脚本的差别：runner 直连 Docker Hub、上行带宽充足，所以直接用 `docker/build-push-action`
的 `push: true`（多平台 manifest 一次成型），**不需要** OCI 归档 + skopeo 兜底；
构建后自动跑冒烟测试，逐个校验 8 个模块是否编入镜像，结果写入 Job Summary。

需要配置的仓库 Secrets（Settings → Secrets and variables → Actions）：

| 名称 | 说明 |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名（`yyong201`） |
| `DOCKERHUB_TOKEN` | Docker Hub **Access Token**（权限 Read & Write），不要用登录密码 |

可选 Variables：`DOCKERHUB_REPO`（默认 `yyong201/caddy2-alpine`）。

注意：本仓库为私有仓库，Actions 会消耗账户额度（单次三平台构建约 10~20 分钟）。

## 文件说明

| 文件 | 说明 |
|---|---|
| `caddy-multiarch-kit.sh` | **一键脚本（推荐）**，自包含，可跨机器分发 |
| `Dockerfile` | 多架构 Dockerfile（交叉编译式），改插件/版本时编辑它 |
| `publish.sh` | 本机专用封装（固定 `--builder rootless` + 本地代理） |
| `.github/workflows/build-image.yml` | CI 多平台构建 + 冒烟测试 |
| `verify_multiarch.py` | 非本机架构二进制抽验（`docker export` + ELF `e_machine` + 模块名 grep，无需 QEMU） |
| `remote_check.py` | 远端 tag / manifest index 校验 |
| `check_auth.py` | Docker Hub token 与 push 权限预检 |

日志与 OCI 归档（`*.log`、`*.tar`）不入库。

## 验证

```bash
docker run --rm yyong201/caddy2-alpine:v2.11.9 caddy list-modules --versions \
  | grep -Ei 'cloudflare|tencentcloud|alidns|forward_proxy|security|webdav|layer4'
```

## 详细 Runbook

Vault → Notes → `infra/docker` →「Caddy 2 多平台镜像构建与发布 Runbook」
（含完整踩坑对照表、插件版本钉法、升级与维护指引）
