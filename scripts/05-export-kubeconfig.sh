#!/usr/bin/env bash
# 导出 kubeconfig：一份留在仓库，一份直接拷到 Windows 的 %USERPROFILE%\.kube\
# 供 Windows 上的 Lens 直接使用
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl
require_cmd kind

log "导出 kubeconfig -> $KUBECONFIG_OUT"
kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_OUT"

SERVER="$(grep -m1 'server:' "$KUBECONFIG_OUT" | awk '{print $2}')"
log "kubeconfig 里的 server = $SERVER（应为 https://127.0.0.1:6443，Docker Desktop 已把它转发到 Windows）"

kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes >/dev/null \
  && log "kubeconfig 自检通过（能列节点）"

# --- 拷到 Windows ------------------------------------------------------------
WIN_KUBE_DIR="${WIN_KUBE_DIR:-}"
if [[ -z "$WIN_KUBE_DIR" ]]; then
  if command -v cmd.exe >/dev/null 2>&1; then
    WIN_PROFILE="$(cmd.exe /c echo %USERPROFILE% 2>/dev/null | tr -d '\r' | sed 's#\\#/#g')"
    [[ -n "$WIN_PROFILE" ]] && WIN_KUBE_DIR="$(wslpath -u "$WIN_PROFILE" 2>/dev/null)/.kube"
  fi
  [[ -z "$WIN_KUBE_DIR" || ! -d "$(dirname "$WIN_KUBE_DIR")" ]] && WIN_KUBE_DIR="/mnt/c/Users/${USER}/.kube"
fi

if [[ -d "$(dirname "$WIN_KUBE_DIR")" ]]; then
  mkdir -p "$WIN_KUBE_DIR"
  cp "$KUBECONFIG_OUT" "$WIN_KUBE_DIR/kind-${CLUSTER_NAME}.yaml"
  log "已拷贝到 Windows：${WIN_KUBE_DIR}/kind-${CLUSTER_NAME}.yaml"

  if [[ -f "$WIN_KUBE_DIR/config" ]]; then
    warn "$WIN_KUBE_DIR/config 已存在，没有覆盖。在 Lens 里用 Add Cluster 粘贴上面这个文件的内容即可。"
    echo "    （想合并成一个 config：KUBECONFIG=$WIN_KUBE_DIR/config:$KUBECONFIG_OUT kubectl config view --flatten > merged.yaml）"
  else
    cp "$KUBECONFIG_OUT" "$WIN_KUBE_DIR/config"
    log "同时写成了 ${WIN_KUBE_DIR}/config（Lens 默认读这个文件）"
  fi
else
  warn "没找到 Windows 的用户目录，跳过拷贝。可在 WSL 里手动执行："
  echo "    cp $KUBECONFIG_OUT /mnt/c/Users/<你的用户名>/.kube/kind-${CLUSTER_NAME}.yaml"
fi

echo
echo "Lens 里确保能看到集群的要点："
echo "  1) Windows 已启动 Docker Desktop，且 kind 集群在运行（kind get clusters）"
echo "  2) API Server 地址是 https://127.0.0.1:6443 —— Lens 里不要改成别的地址"
echo "  3) 集群重建后（kind delete/create）必须重新执行本脚本，因为客户端证书变了"
