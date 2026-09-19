#!/usr/bin/env bash
# 恢复集群：Docker Desktop 重启/关机重启后，kind 的节点容器不会自动拉起
# （kind 用的是 --restart=on-failure:1 策略），用这个脚本把它们启动起来即可，不用重建。
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker
require_cmd kubectl

for n in "${CLUSTER_NAME}-control-plane" "$WORKER01" "$WORKER02"; do
  state="$(docker inspect -f '{{.State.Running}}' "$n" 2>/dev/null || echo missing)"
  case "$state" in
    true)  log "已在运行：$n" ;;
    false) log "启动节点容器：$n"; docker start "$n" >/dev/null ;;
    *)     die "找不到节点容器 $n，集群可能已被删除（kind get clusters）" ;;
  esac
done

log "等待节点 Ready（首次约 10~60 秒）"
kubectl --context "kind-${CLUSTER_NAME}" wait --for=condition=Ready nodes --all --timeout=180s
kubectl --context "kind-${CLUSTER_NAME}" get nodes -L vtf.io/worker
kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" get pods -o wide
