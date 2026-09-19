#!/usr/bin/env bash
# 安装 kind + kubectl 到 ~/.local/bin（需要能访问外网）
# helm 是可选的（只有想用 Helm 装 ingress-nginx 时才需要）
set -euo pipefail

ARCH="$(dpkg --print-architecture)"   # amd64 / arm64
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

# WSL 里 IPv6 常常不可用（curl 会先试 IPv6 然后一直卡住），统一强制 IPv4 + 超时 + 重试
CURL=(curl -4 -fsSL --connect-timeout 15 --retry 3 --retry-delay 2)

# --- kubectl -----------------------------------------------------------------
# 默认跟集群同一个 minor（stable-1.36.txt = 1.36 的最新 patch）
KUBECTL_VERSION="${KUBECTL_VERSION:-$("${CURL[@]}" https://dl.k8s.io/release/stable-1.36.txt)}"
echo "==> 安装 kubectl ${KUBECTL_VERSION}"
"${CURL[@]}" -o "$BIN_DIR/kubectl" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
chmod +x "$BIN_DIR/kubectl"

# --- kind --------------------------------------------------------------------
# 注意：跑 K8s 1.36 需要足够新的 kind，默认取 GitHub 上最新 release
if [[ -z "${KIND_VERSION:-}" ]]; then
  KIND_VERSION="$("${CURL[@]}" https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')"
fi
echo "==> 安装 kind ${KIND_VERSION}"
"${CURL[@]}" -o "$BIN_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x "$BIN_DIR/kind"

# --- helm（可选，装不上不影响主流程）------------------------------------------
if [[ "${INSTALL_HELM:-0}" == "1" ]]; then
  HELM_VERSION="${HELM_VERSION:-$("${CURL[@]}" https://api.github.com/repos/helm/helm/releases/latest \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\(v[^"]*\)"/\1/')}"
  echo "==> 安装 helm ${HELM_VERSION}"
  TMP="$(mktemp -d)"
  "${CURL[@]}" "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xz -C "$TMP"
  install -m 0755 "$TMP/linux-${ARCH}/helm" "$BIN_DIR/helm"
  rm -rf "$TMP"
fi

echo
echo "==> 版本确认"
"$BIN_DIR/kubectl" version --client
"$BIN_DIR/kind" version

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo; echo "提示：把 $BIN_DIR 加进 PATH："; echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;;
esac
