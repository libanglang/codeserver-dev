#!/usr/bin/env bash
# 把开发机镜像推到 Docker Hub（ACR 权限没到位时的替代方案）
#
# 用法：
#   1) 先登录一次（密码或 Access Token 由你自己输入，脚本/我不接触）：
#        docker login -u <你的DockerHub用户名>
#   2) 然后：
#        bash scripts/15-push-to-dockerhub.sh
#        DOCKERHUB_REPO=codeserver-dev TAG=v1 bash scripts/15-push-to-dockerhub.sh
#
# 注意：
#   * Docker Hub 免费账号：**公开仓库不限**；私有仓库免费额度有限（要私有请在网页端先建）
#   * 推送/拉取走 Docker 引擎（Docker Desktop），WSL 里 curl 直连不通不影响
#   * 中国大陆的 ACK 节点直连 Docker Hub 往往很慢甚至不通 —— 需要给 ACK 配镜像加速，
#     或者等 ACR 权限下来后改推 ACR（见 scripts/13-push-to-acr.sh）
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker

# 默认推送"当前 Deployment 正在用的那个本地镜像"
if [[ -z "${IMAGE:-}" ]]; then
  IMAGE="$(kubectl --context "kind-${CLUSTER_NAME}" -n "$NAMESPACE" get deploy codeserver-lqm \
           -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  IMAGE="${IMAGE:-vtf/codeserver-dev:8}"
fi
TAG="${TAG:-${IMAGE##*:}}"
DOCKERHUB_REPO="${DOCKERHUB_REPO:-codeserver-dev}"

# --- 取 Docker Hub 用户名（凭据本身不打印、不使用，只读用户名）------------------
hub_user="${DOCKERHUB_USER:-}"
if [[ -z "$hub_user" ]]; then
  for helper in docker-credential-desktop.exe docker-credential-desktop docker-credential-pass docker-credential-osxkeychain; do
    command -v "$helper" >/dev/null 2>&1 || continue
    out="$(printf 'https://index.docker.io/v1/' | "$helper" get 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      hub_user="$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("Username",""))' 2>/dev/null || true)"
      [[ -n "$hub_user" ]] && break
    fi
  done
fi

if [[ -z "$hub_user" ]]; then
  warn "本机还没有 Docker Hub 登录凭据。先执行（密码/Access Token 由你自己输入）："
  echo "    docker login -u <你的DockerHub用户名>"
  echo "然后重跑： bash scripts/15-push-to-dockerhub.sh"
  echo
  echo "提示：Docker Hub 控制台 → Account settings → Personal access tokens 可以生成 PAT；"
  echo "      开了两步验证的账号必须用 PAT 当密码。"
  exit 1
fi

TARGET="${hub_user}/${DOCKERHUB_REPO}:${TAG}"

log "源镜像    : $IMAGE"
log "Docker Hub: $hub_user/${DOCKERHUB_REPO}:${TAG}"

docker tag "$IMAGE" "$TARGET"
log "推送中（压缩后约 1.1GB，取决于上行带宽）…"
docker push "$TARGET"

DIGEST="$(docker image inspect "$TARGET" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//' || true)"

cat <<EOF

推送完成 ✓
  镜像地址: docker.io/${TARGET}
  网页查看: https://hub.docker.com/r/${hub_user}/${DOCKERHUB_REPO}
  digest  : ${DIGEST:-（docker 未记录 digest，可在网页端查看）}

在 ACK 里引用（注意中国大陆节点直连 Docker Hub 慢，建议先给集群配镜像加速）：
  image: ${TARGET}

几点提醒：
  * 免费账号的仓库默认是**公开**的；这个镜像里没有任何密钥（~/.codex/env、~/.ssh 都在 PVC/HOME 里，不在镜像里），但仍建议检查一遍再公开
  * Docker Hub 有拉取限流（匿名 100 次/6h/IP，登录 200 次/6h），ACK 多节点频繁重建可能触顶
  * 长期建议还是回到 ACR（scripts/13-push-to-acr.sh），内网拉取、无限流
EOF
