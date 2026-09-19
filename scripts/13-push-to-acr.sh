#!/usr/bin/env bash
# 把开发机镜像推送到阿里云 ACR。
#
# 关键：ACR 有两个端点，不能混用（本机实测）：
#   your-acr-registry.cn-hangzhou.cr.aliyuncs.com       公网端点 —— 本地推送用这个
#   your-acr-registry-vpc.cn-hangzhou.cr.aliyuncs.com   VPC 端点  —— 只在阿里云 VPC 内可用
#                                                      （本地 DNS 都解析不出来，ACK 里用它是内网、免公网流量）
#
# 用法：
#   ACR_NAMESPACE=<你的ACR命名空间> bash scripts/13-push-to-acr.sh
#   ACR_NAMESPACE=xxx TAG=7 IMAGE=vtf/codeserver-dev:7 bash scripts/13-push-to-acr.sh
#   非交互（CI 用）：ACR_PASSWORD=*** ACR_NAMESPACE=xxx bash scripts/13-push-to-acr.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker

# 默认推送"当前 Deployment 正在用的那个本地镜像"（避免写死 tag 后失效）
if [[ -z "${IMAGE:-}" ]]; then
  IMAGE="$(kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" get deploy codeserver-lqm \
           -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  IMAGE="${IMAGE:-vtf/codeserver-dev:8}"
fi
TAG="${TAG:-${IMAGE##*:}}"
ACR_REGISTRY="${ACR_REGISTRY:-your-acr-registry.cn-hangzhou.cr.aliyuncs.com}"
ACR_VPC_REGISTRY="${ACR_VPC_REGISTRY:-${ACR_REGISTRY/.cn-hangzhou.cr.aliyuncs.com/-vpc.cn-hangzhou.cr.aliyuncs.com}}"
ACR_USER="${ACR_USER:-<your-acr-username@your-account-id>}"
ACR_NAMESPACE="${ACR_NAMESPACE:-}"
ACR_REPO="${ACR_REPO:-codeserver-dev}"

log "源镜像        : $IMAGE"

# --- 1) 登录（密码不要写进仓库；交互输入或从环境变量读）------------------------
if [[ -n "${ACR_PASSWORD:-}" ]]; then
  printf '%s' "$ACR_PASSWORD" | docker login --username "$ACR_USER" --password-stdin "$ACR_REGISTRY"
else
  log "请输入 ACR 密码（ACR 控制台 → 访问凭证 里设置的固定密码；输入不回显、不落盘）"
  docker login --username "$ACR_USER" "$ACR_REGISTRY"
fi

# --- 1.5) 没给命名空间就自动识别（用刚登录的凭据查仓库列表）--------------------
discover_namespaces() {
  local auth
  auth="$(python3 - "$HOME/.docker/config.json" "$ACR_REGISTRY" <<'PY' 2>/dev/null || true
import base64, json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
host = sys.argv[2].split("/")[0]
for k, v in cfg.get("auths", {}).items():
    if host in k and v.get("auth"):
        print(base64.b64decode(v["auth"]).decode())
        break
PY
)"
  [[ -n "$auth" ]] || return 0
  curl -sf -u "$auth" "https://${ACR_REGISTRY}/v2/_catalog?n=200" 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ns=sorted({r.split("/")[0] for r in d.get("repositories", []) if "/" in r})
print("\n".join(ns))' 2>/dev/null || true
}

if [[ -z "$ACR_NAMESPACE" ]]; then
  log "未指定 ACR_NAMESPACE，尝试从 ACR 仓库列表自动识别命名空间…"
  ns_list="$(discover_namespaces)"
  if [[ -n "$ns_list" ]]; then
    ns_count="$(printf '%s\n' "$ns_list" | wc -l)"
    if [[ "$ns_count" == "1" ]]; then
      ACR_NAMESPACE="$ns_list"
      log "识别到命名空间：$ACR_NAMESPACE"
    else
      die "ACR 里有多个命名空间，请显式指定其一：$(printf '%s' "$ns_list" | tr '\n' ' ')"
    fi
  else
    die "无法自动识别命名空间（仓库为空或未拿到凭据）。请显式指定：ACR_NAMESPACE=<你的命名空间> bash scripts/13-push-to-acr.sh"
  fi
fi

TARGET="${ACR_REGISTRY}/${ACR_NAMESPACE}/${ACR_REPO}:${TAG}"
VPC_TARGET="${ACR_VPC_REGISTRY}/${ACR_NAMESPACE}/${ACR_REPO}:${TAG}"
log "本地推送目标  : $TARGET"

# --- 2) 打标签 + 推送 --------------------------------------------------------
docker tag "$IMAGE" "$TARGET"
log "推送中（首次推 3~4GB，取决于上行带宽）..."
docker push "$TARGET"

# --- 3) 取出 digest（ACK 里按 digest 引用最稳）--------------------------------
DIGEST="$(docker image inspect "$TARGET" --format '{{index .RepoDigests 0}}' | sed 's/.*@//')"

cat <<EOF

推送完成 ✓
  digest: ${DIGEST}

本地 / kind 引用（公网）：
  ${TARGET}
ACK 引用（VPC 内网，推荐）：
  ${VPC_TARGET}@${DIGEST}

ACK 里怎么用：
  1) 免密拉取：ACK 控制台安装「aliyun-acr-credential-helper」组件，之后同账号的 ACR 直接可拉
     或手动建 ImagePullSecret：
       kubectl -n <ns> create secret docker-registry acr-credential \\
         --docker-server=${ACR_VPC_REGISTRY} \\
         --docker-username='${ACR_USER}' --docker-password='<你的ACR密码>'
       然后在 Deployment 里加 imagePullSecrets: [{name: acr-credential}]
  2) 把 Deployment 的 image 换成上面的 VPC 地址 + digest
  3) 一致性自检（换环境后跑一次）：
       IMAGE=${VPC_TARGET}@${DIGEST} bash scripts/12-verify-image-parity.sh

注意：
  * 本地千万别用 -vpc 端点（解析不了）；ACK 里千万别用公网端点（慢且计公网流量）
  * 换镜像就换 TAG，不要覆盖已有 tag，避免 kind 和 ACK 拉到不同内容
  * ACK 节点是 ARM 实例时，先 buildx 多架构构建再推：
      docker buildx build --platform linux/amd64,linux/arm64 -t ${TARGET} --push image/
EOF
