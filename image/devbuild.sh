#!/bin/sh
# devbuild —— 在开发机容器里构建镜像并直接推送到镜像仓库
#
# 开发机 Pod 是非特权的，容器内不能自己跑容器构建；镜像构建统一交给集群里的
# BuildKit 服务（manifests/30-buildkitd.yaml），本容器只做客户端。
#
# 用法:
#   devbuild -t <registry>/<命名空间>/<仓库>:<标签> [-f Dockerfile] [构建上下文] [--insecure]
#
# 例子:
#   cd /workspace/myapp
#   devbuild -t registry.cn-hangzhou.aliyuncs.com/myns/myapp:1.0 .            # 推公网 ACR
#   devbuild -t registry.dev.svc.cluster.local:5000/myapp:1 --insecure .      # 推集群内 HTTP registry
#
# 私有仓库先登录（凭据会被 buildctl 用来推镜像）:
#   podman login --authfile ~/.docker/config.json -u <用户名> <registry>
#
# 可用环境变量:
#   BUILDKIT_HOST  默认 tcp://buildkitd.dev.svc.cluster.local:1234
set -eu

BUILDKIT_HOST="${BUILDKIT_HOST:-tcp://buildkitd.dev.svc.cluster.local:1234}"
tag=""
dockerfile="Dockerfile"
ctx="."
insecure=0

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--tag) tag="${2:-}"; shift 2 ;;
    -f|--file) dockerfile="${2:-}"; shift 2 ;;
    --insecure) insecure=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ctx="$1"; shift ;;
  esac
done

if [ -z "$tag" ]; then
  echo "错误：必须用 -t 指定目标镜像，例如：devbuild -t <registry>/<ns>/<repo>:<tag> ." >&2
  exit 2
fi
if [ ! -f "$ctx/$dockerfile" ]; then
  echo "错误：找不到 Dockerfile：$ctx/$dockerfile" >&2
  exit 2
fi
command -v buildctl >/dev/null 2>&1 || { echo "错误：镜像里没有 buildctl（需要 vtf/codeserver-dev:8 及以上）" >&2; exit 3; }

output="type=image,name=$tag,push=true"
[ "$insecure" = "1" ] && output="$output,registry.insecure=true"

echo ">> BuildKit : $BUILDKIT_HOST"
echo ">> 目标镜像: $tag"
echo ">> 上下文  : $ctx   Dockerfile: $dockerfile"

exec buildctl --addr "$BUILDKIT_HOST" build \
  --frontend dockerfile.v0 \
  --local "context=$ctx" \
  --local "dockerfile=$(dirname "$ctx/$dockerfile")" \
  --opt "filename=$(basename "$dockerfile")" \
  --opt "platform=linux/amd64" \
  --output "$output"
