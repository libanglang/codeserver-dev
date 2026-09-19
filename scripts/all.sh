#!/usr/bin/env bash
# 一把梭：装工具 -> 建集群 -> 装 ingress -> 准备 hostPath -> 部署 -> 导出 kubeconfig -> 自检
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v kind >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
  bash "$HERE/00-install-tools.sh"
  export PATH="$HOME/.local/bin:$PATH"
fi

bash "$HERE/01-create-cluster.sh"
bash "$HERE/03-install-ingress.sh"
bash "$HERE/02-prepare-worker02.sh"
bash "$HERE/04-deploy-codeserver.sh"
bash "$HERE/05-export-kubeconfig.sh"
bash "$HERE/06-verify.sh"
