#!/usr/bin/env bash
# 校验「本地 kind 用的镜像」与「集群里正在跑的镜像」是同一份内容：
#   1) 两边各跑一次镜像内置的 image-selfcheck
#   2) 只比较 [image] 段（镜像里烧死的东西）——必须完全一致
#   3) 打印两边镜像 ID / 摘要，便于核对
#   4) [platform]/[mounts] 段本来就该不同，只做展示不做断言
#
# 用法：
#   bash scripts/12-verify-image-parity.sh
#   IMAGE=vtf/codeserver-dev:6 APPS="lqm yl zk" bash scripts/12-verify-image-parity.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker
require_cmd kubectl

APPS="${APPS:-lqm yl zk}"
CTX="kind-${CLUSTER_NAME}"

# 默认不写死 tag（写死会随部署升级而失效，产生"假差异"）：
# 直接取当前 Deployment 正在用的镜像作为对比基准。
if [[ -z "${IMAGE:-}" ]]; then
  first_app="${APPS%% *}"
  IMAGE="$(kubectl --context "$CTX" -n "$NAMESPACE" get deploy "codeserver-${first_app}" \
           -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [[ -n "$IMAGE" ]] || die "无法从 Deployment 推断镜像，请显式指定：IMAGE=<镜像> bash scripts/12-verify-image-parity.sh"
  log "未指定 IMAGE，按 Deployment 当前镜像取值：$IMAGE"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  warn "本地没有镜像 $IMAGE（例如部署已切到 ACR 地址）。"
  warn "请用本地构建的那个 tag 做对比，例如：IMAGE=vtf/codeserver-dev:7 bash scripts/12-verify-image-parity.sh"
  die "无法在本地运行该镜像，无法比对"
fi

extract_image_section() { sed -n '/^\[image\]/,/^\[platform\]/p' | sed '$d'; }

log "本地镜像：$IMAGE"
docker image inspect "$IMAGE" --format '  Id={{.Id}}{{"\n"}}  Arch={{.Architecture}}/{{.Os}}' | sed 's/^/  /'
local_out="$(docker run --rm --entrypoint image-selfcheck "$IMAGE" 2>/dev/null)"

rc=0
for app in $APPS; do
  pod="$(kubectl --context "$CTX" -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=codeserver-${app}" \
        -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || { warn "找不到 codeserver-${app} 的 Pod，跳过"; continue; }
  log "集群侧：codeserver-${app}（pod=${pod}）"
  kubectl --context "$CTX" -n "$NAMESPACE" get pod "$pod" \
    -o jsonpath='  image={.spec.containers[0].image}{"\n"}  imageID={.status.containerStatuses[0].imageID}{"\n"}' | sed 's/^/  /'
  echo "  （imageID 是 containerd 导入后的本地摘要，和 Docker 侧 ID 天然不同，不作为判据）"
  pod_out="$(kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- image-selfcheck 2>/dev/null)"

  if diff <(printf '%s\n' "$local_out" | extract_image_section) \
          <(printf '%s\n' "$pod_out"   | extract_image_section) > /tmp/parity.diff; then
    echo "  [image] 段对比：完全一致 ✓"
  else
    warn "  [image] 段存在差异（见下），说明两边跑的不是同一份镜像内容："
    sed 's/^/    /' /tmp/parity.diff
    rc=1
  fi
done

echo
if [[ "$rc" == "0" ]]; then
  log "结论：本地与集群使用同一份镜像内容 ✓"
else
  die "结论：存在差异 —— 检查两边是不是同一个 tag/digest，或镜像被重新构建过"
fi

cat <<'TIP'

要保证长期一致（推到阿里云 ACK 后同样适用）：
  1) 只用「构建一次」的镜像：本地构建 → 打 tag → 推 ACR → kind 和 ACK 都按 digest 引用
     docker tag vtf/codeserver-dev:6 registry.cn-<region>.aliyuncs.com/<ns>/codeserver-dev:6
     docker push registry.cn-<region>.aliyuncs.com/<ns>/codeserver-dev:6
     kubectl -n dev set image deploy/codeserver-lqm code-server=registry.../codeserver-dev:6@sha256:<digest>
  2) 改镜像就改 tag（:7），别覆盖 :6；ACK 里用 digest 引用最稳
  3) 多架构：ACK 节点若是 arm64，构建时加 --platform linux/amd64,linux/arm64（buildx）
  4) 换环境后重跑本脚本：bash scripts/12-verify-image-parity.sh
TIP
