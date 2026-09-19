#!/usr/bin/env bash
# 在**节点上**直接拉取镜像（ACK / kind 通用，不需要 SSH、不需要节点密钥）
#
# 原理：kubectl debug node/<node> 会起一个挂载了节点根文件系统的特权 Pod，
#       chroot /host 进去就等于"站在节点上"，用节点的 crictl 拉取（ACK 节点是 containerd）。
#
# 用法：
#   NODE=cn-hangzhou.10.0.1.23 bash scripts/16-pull-on-node.sh
#   NODE=<节点名> IMAGE=docker.io/<your-dockerhub-user>/codeserver-dev:8 bash scripts/16-pull-on-node.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl

NODE="${NODE:-}"
[[ -n "$NODE" ]] || die "需要指定节点：NODE=<节点名> bash scripts/16-pull-on-node.sh
  查节点名：kubectl get nodes -o wide"
IMAGE="${IMAGE:-docker.io/<your-dockerhub-user>/codeserver-dev:8}"
DEBUG_IMAGE="${DEBUG_IMAGE:-busybox:1.36}"
CTX="kind-${CLUSTER_NAME}"

log "节点 : $NODE"
log "镜像 : $IMAGE"

run_on_node() { # $1=在节点上执行的命令
  kubectl --context "$CTX" debug "node/$NODE" --image="$DEBUG_IMAGE" \
    --attach=true --stdin=false -- chroot /host sh -c "$1"
}

log "① 先看节点到 Docker Hub 的网络（401=通；超时/000=不通，需要配镜像加速）"
run_on_node 'curl -s -o /dev/null -w "registry-1.docker.io -> %{http_code}\n" -m 12 https://registry-1.docker.io/v2/ || echo "registry-1.docker.io -> 连不上"' || true

log "② 用节点的 crictl 拉取"
run_on_node "crictl pull '$IMAGE' && echo '拉取成功'"

log "③ 确认镜像已在节点上"
run_on_node "crictl images | grep -E 'REPOSITORY|codeserver-dev' | head -5"

echo
echo "说明："
echo "  * 每个节点各自维护镜像缓存 —— 只在这一台拉，别的节点还会自己拉一次。"
echo "    想让所有节点都有，用 DaemonSet 预热，或直接部署业务 Pod 让它按需拉。"
echo "  * 拉到节点上的镜像，Pod 引用时建议写全 docker.io/<your-dockerhub-user>/codeserver-dev:8，"
echo "    并把 imagePullPolicy 设为 IfNotPresent，避免又去外网拉一次。"
echo "  * 如果第①步不通（大陆节点常见），先配 containerd 镜像加速，再重跑本脚本。"
