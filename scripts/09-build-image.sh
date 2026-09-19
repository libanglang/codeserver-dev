#!/usr/bin/env bash
# 构建带工具链的开发机镜像 -> 载入 kind 三个节点 -> 切换三台开发机
# 用法：
#   bash scripts/09-build-image.sh
#   WITH_JAVA=1 WITH_GO=1 WITH_RUST=1 bash scripts/09-build-image.sh
#   IMAGE=vtf/codeserver-dev:v2 bash scripts/09-build-image.sh
#   LOAD=0 SWITCH=0 bash scripts/09-build-image.sh     # 只构建，不动集群
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker
require_cmd kind
require_cmd kubectl

IMAGE="${IMAGE:-vtf/codeserver-dev:1}"
WITH_JAVA="${WITH_JAVA:-0}"
# 与 image/Dockerfile 的默认值保持一致：Go 默认装上（脚本里显式传参会覆盖 Dockerfile 的 ARG 默认值，
# 所以这里必须也是 1，否则会把 Go 关掉）
WITH_GO="${WITH_GO:-1}"
WITH_RUST="${WITH_RUST:-0}"
WITH_KUBECTL="${WITH_KUBECTL:-1}"
LOAD="${LOAD:-1}"       # 1=把镜像载入 kind 三个节点
SWITCH="${SWITCH:-1}"   # 1=把三台开发机切到新镜像

log "构建镜像 $IMAGE (java=$WITH_JAVA go=$WITH_GO rust=$WITH_RUST kubectl=$WITH_KUBECTL)"
log "首次构建要下几百 MB 的 deb 包，慢是正常的"
docker build -t "$IMAGE" \
  --build-arg WITH_JAVA="$WITH_JAVA" \
  --build-arg WITH_GO="$WITH_GO" \
  --build-arg WITH_RUST="$WITH_RUST" \
  --build-arg WITH_KUBECTL="$WITH_KUBECTL" \
  "${REPO_ROOT}/image"

if [[ "$LOAD" == "1" ]]; then
  log "载入 kind 节点（三个节点都要，否则会有节点拉不到镜像）"
  kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"
fi

if [[ "$SWITCH" == "1" ]]; then
  log "切换三台开发机的镜像"
  for d in codeserver-lqm codeserver-yl codeserver-zk; do
    kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" set image "deployment/$d" "code-server=$IMAGE"
  done
  for d in codeserver-lqm codeserver-yl codeserver-zk; do
    kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" rollout status "deployment/$d" --timeout=300s
  done
else
  log "SWITCH=0，未改动运行中的开发机"
fi

log "镜像内工具链自检（直接起一个容器看，不依赖集群）"
docker run --rm -u 1001:1001 -e HOME=/tmp --entrypoint sh "$IMAGE" -c \
  'for c in gcc g++ make cmake python3 pip3 node npm git go java rustc kubectl codex podman buildah skopeo; do printf "  %-8s %s\n" "$c" "$(command -v $c || echo -)"; done'

echo
if [[ "$SWITCH" == "1" ]]; then
  warn "记得把 manifests/10-codeserver-apps.yaml 里的 image 也改成 $IMAGE，"
  warn "否则下次 kubectl apply / bash scripts/04-deploy-codeserver.sh 会退回到旧镜像。"
else
  log "下一步：LOAD=1 SWITCH=1 bash scripts/09-build-image.sh 或手动 kubectl -n dev set image"
fi
