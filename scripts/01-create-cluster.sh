#!/usr/bin/env bash
# 创建 kind 多节点集群：1 控制面 + 2 worker（K8s 版本见 kind/kind-cluster.yaml）
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker
require_cmd kind
require_cmd kubectl

# Docker Desktop 的 WSL 集成没开时，docker 命令会提示 "could not be found in this WSL 2 distro"
if ! docker info >/dev/null 2>&1; then
  die "连不上 Docker。请先启动 Docker Desktop（Windows 托盘图标变绿），
    并在 Settings -> Resources -> WSL integration 里勾选当前发行版（本机是 Ubuntu-24.04）。"
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  warn "集群 $CLUSTER_NAME 已存在，跳过创建（要重建请先 bash scripts/99-teardown.sh）"
else
  log "创建 cluster=${CLUSTER_NAME} image=${KIND_IMAGE}"
  log "配置文件：$KIND_CONFIG"
  # 1.36 的 node 镜像尚未发布时，kind 会直接报错，可改用 v1.36.x 的实际 tag
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$KIND_CONFIG" \
    --wait 240s
fi

CTX="kind-${CLUSTER_NAME}"

# 幂等补/修正 worker 标签（kind 里 worker 名叫 <cluster>-worker / <cluster>-worker2）
log "打节点标签：worker01 / worker02"
kubectl --context "$CTX" label node "$WORKER01" vtf.io/worker=worker01 --overwrite
kubectl --context "$CTX" label node "$WORKER02" vtf.io/worker=worker02 --overwrite

log "集群状态"
kubectl --context "$CTX" get nodes -L vtf.io/worker,ingress-ready -o wide
log "节点名映射：$WORKER01 -> worker01（普通 worker），$WORKER02 -> worker02（承载 code-server）"
