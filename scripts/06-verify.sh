#!/usr/bin/env bash
# 端到端自检：集群 -> 调度位置 -> hostPath -> Ingress -> HTTP 状态码
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl

CTX="kind-${CLUSTER_NAME}"
NS="$NAMESPACE"

log "1. 节点（版本应为 v1.36.x，标签 vtf.io/worker=worker01/worker02）"
kubectl --context "$CTX" get nodes -L vtf.io/worker

log "2. Pod（NODE 列必须都是 ${WORKER02}）"
kubectl --context "$CTX" -n "$NS" get pods -o wide

log "3. 三台之间的隔离（uid 各不相同 / 只有自己的 /workspace 可写 / 看不到节点路径）"
for item in $CODESERVER_APPS; do
  name="${item%%:*}"
  uuid="${item##*:}"
  printf '  codeserver-%s （期望 uid=%s，容器内 /workspace -> 节点 %s/%s）\n' "$name" "$uuid" "$BASE_DATA_DIR" "$name"
  kubectl --context "$CTX" -n "$NS" exec "deploy/codeserver-$name" -- sh -c "
    printf '    uid = %s, /workspace 属主(数字) = %s, 权限 = %s\n' \"\$(id -u)\" \"\$(stat -c %u /workspace)\" \"\$(stat -c %a /workspace)\"
    touch /workspace/.rw-test && rm -f /workspace/.rw-test && echo '    /workspace: 可读写 ✓'
    printf '    /workspace 内容: [%s]\n' \"\$(ls -A /workspace | tr '\n' ' ')\"
  " || warn "codeserver-$name 自检失败"

  # 节点上的路径不应该出现在容器里（挂载点已改为 /workspace）
  if kubectl --context "$CTX" -n "$NS" exec "deploy/codeserver-$name" -- \
       sh -c "test -e /data" >/dev/null 2>&1; then
    warn "    容器里仍能看到节点路径 /data —— 检查 mountPath 是否是 /workspace"
  else
    echo "    节点路径 /data/... : 容器内不可见 ✓"
  fi

  # 别人的目录更不应该可见
  for other in $CODESERVER_APPS; do
    oname="${other%%:*}"
    [[ "$oname" == "$name" ]] && continue
    if kubectl --context "$CTX" -n "$NS" exec "deploy/codeserver-$name" -- \
         sh -c "test -e $BASE_DATA_DIR/$oname" >/dev/null 2>&1; then
      warn "    $BASE_DATA_DIR/$oname 居然可见 —— 隔离失效"
    else
      echo "    $oname 的目录: 不可见 ✓"
    fi
  done
done

log "4. Ingress"
kubectl --context "$CTX" -n "$NS" get ingress
kubectl --context "$CTX" -n ingress-nginx get pods

log "5. HTTP 探测（在 WSL 里直接打宿主 80 端口，带 Host 头模拟域名）"
for p in lqm yl zk; do
  for suffix in "" "/"; do
    url="http://127.0.0.1/dev/group/vtf/${p}${suffix}"
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${INGRESS_HOST}" "$url" || true)"
    printf '  %-58s -> %s\n' "$url" "${code:-curl failed}"
  done
done
echo "  说明：裸路径 301 是补结尾斜杠；带斜杠 302 是 code-server 跳登录页 —— 这两种都算正常。"
echo "       404 说明前缀剥离/路由没生效，检查 manifests/20-ingress.yaml 与 ingress-nginx 是否正常。"

echo
echo "浏览器地址（Windows 浏览器，先在 hosts 里加 127.0.0.1 ${INGRESS_HOST}）："
echo "  http://${INGRESS_HOST}/dev/group/vtf/lqm/"
echo "  http://${INGRESS_HOST}/dev/group/vtf/yl/"
echo "  http://${INGRESS_HOST}/dev/group/vtf/zk/"
echo "三台的密码（各自独立，来自 Secret codeserver-passwords）："
kubectl --context "$CTX" -n "$NS" get secret codeserver-passwords \
  -o go-template='{{range $k,$v := .data}}  {{$k}}{{"\t"}}{{$v | base64decode}}{{"\n"}}{{end}}'
echo "  改密码：编辑 manifests/05-codeserver-passwords.yaml 后 kubectl apply，再 rollout restart deploy"
