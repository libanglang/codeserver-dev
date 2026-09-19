#!/usr/bin/env bash
# 安装 ingress-nginx（kind 官方适配版）：控制器跑在带 ingress-ready=true 的控制面上，
# 通过 hostPort 占用 80/443，正好对上 kind 里做的 extraPortMappings
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl

CTX="kind-${CLUSTER_NAME}"
MANIFEST_URL="${INGRESS_MANIFEST_URL:-https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml}"

log "安装 ingress-nginx：$MANIFEST_URL"
kubectl --context "$CTX" apply -f "$MANIFEST_URL"

# 重要：新版 kind 适配清单里的 controller 只写了 nodeSelector kubernetes.io/os=linux，
# 不再固定 ingress-ready=true，控制器可能被调度到没有 80 端口映射的 worker 上，
# 那样从 Windows 就访问不到。这里强制钉到带 ingress-ready 标签的控制面节点。
log "把 controller 钉到 ingress-ready=true 的节点（宿主 80 端口映射在这个节点上）"
kubectl --context "$CTX" -n ingress-nginx patch deployment ingress-nginx-controller --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}'

log "等待 controller 就绪（首次拉镜像可能 1~3 分钟）"
kubectl --context "$CTX" -n ingress-nginx wait \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

kubectl --context "$CTX" -n ingress-nginx get pods -o wide
kubectl --context "$CTX" get ingressclass
