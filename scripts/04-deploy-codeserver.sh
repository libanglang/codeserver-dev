#!/usr/bin/env bash
# 创建 namespace / 密码 Secret，部署三台 code-server + Ingress，并等 Pod 就绪
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl

CTX="kind-${CLUSTER_NAME}"
NS="$NAMESPACE"

kubectl --context "$CTX" apply -f "${REPO_ROOT}/manifests/00-namespace.yaml"

# --- 登录密码：三台各自独立，定义在 manifests/05-codeserver-passwords.yaml ----
kubectl --context "$CTX" apply -f "${REPO_ROOT}/manifests/05-codeserver-passwords.yaml"
# 清理早期版本共用的密码 Secret（已不再被引用）
kubectl --context "$CTX" -n "$NS" delete secret codeserver-password --ignore-not-found >/dev/null

# --- 部署 --------------------------------------------------------------------
kubectl --context "$CTX" apply -f "${REPO_ROOT}/manifests/10-codeserver-apps.yaml"
kubectl --context "$CTX" apply -f "${REPO_ROOT}/manifests/20-ingress.yaml"

for d in codeserver-lqm codeserver-yl codeserver-zk; do
  log "等待 deployment/$d 就绪"
  kubectl --context "$CTX" -n "$NS" rollout status "deployment/$d" --timeout=300s
done

log "Pod 分布（必须都在 ${WORKER02} 上）："
kubectl --context "$CTX" -n "$NS" get pods -o wide

echo
log "三台的密码（各自独立，来自 Secret codeserver-passwords）："
kubectl --context "$CTX" -n "$NS" get secret codeserver-passwords \
  -o go-template='{{range $k,$v := .data}}  {{$k}}{{"\t"}}{{$v | base64decode}}{{"\n"}}{{end}}'
echo "访问地址（浏览器，建议带结尾的 /，并把 http:// 写全）："
echo "  http://${INGRESS_HOST}/dev/group/vtf/lqm/   密码见上表 lqm"
echo "  http://${INGRESS_HOST}/dev/group/vtf/yl/    密码见上表 yl"
echo "  http://${INGRESS_HOST}/dev/group/vtf/zk/    密码见上表 zk"
echo "提示：三台在同一个浏览器里会共用 origin，Chrome 可能把 lqm 的密码自动填充到另外两台，"
echo "      看到自动填充的密码直接改成对应的那个再登录。"
