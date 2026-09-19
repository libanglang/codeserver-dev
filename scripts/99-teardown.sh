#!/usr/bin/env bash
# 删除 kind 集群（会删掉节点容器里的数据）并清理本地 kubeconfig 文件
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kind

warn "即将删除集群 $CLUSTER_NAME。"
if [[ "$KIND_CONFIG" == *"hostdata"* ]]; then
  echo "  （方案 B：数据在 WSL 的 extraMounts 目录里，不受影响）"
else
  echo "  （方案 A：hostPath 数据在节点容器里，删除后 /data/group/vtf/* 会一起消失！）"
  echo "   需要保留的话先备份：docker cp ${WORKER02}:/data/group/vtf ./vtf-data-backup"
fi
read -r -p "确认删除？输入 yes 继续: " ans
[[ "$ans" == "yes" ]] || { echo "已取消"; exit 0; }

kind delete cluster --name "$CLUSTER_NAME"
rm -f "$KUBECONFIG_OUT"
log "已删除。Windows 上的 %USERPROFILE%\\.kube\\kind-${CLUSTER_NAME}.yaml 请手动删掉，避免残留连接报错。"
