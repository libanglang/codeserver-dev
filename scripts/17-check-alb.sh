#!/usr/bin/env bash
# 体检 ACK 的 ALB Ingress 是否就绪（AlbConfig / IngressClass / 控制器）
#
# 用法（用 ACK 的 kubeconfig 执行，不要用 kind 的）：
#   KUBECONFIG=~/.kube/ack-config bash scripts/17-check-alb.sh
#   bash scripts/17-check-alb.sh <context名>
set -uo pipefail

CTX_ARG="${1:-}"
KUBECTL=(kubectl)
[[ -n "$CTX_ARG" ]] && KUBECTL+=(--context "$CTX_ARG")

line() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
no()   { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*"; }

line "当前上下文（确认是 ACK，不是 kind）"
"${KUBECTL[@]}" config current-context 2>/dev/null | sed 's/^/  /'
if "${KUBECTL[@]}" get nodes -o name 2>/dev/null | grep -q "kind-"; then
  warn "这看起来是 kind 集群，请改用 ACK 的 kubeconfig"
fi

line "1) IngressClass"
if "${KUBECTL[@]}" get ingressclass 2>/dev/null | grep -q .; then
  "${KUBECTL[@]}" get ingressclass -o custom-columns=\
'NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class,PARAM_KIND:.spec.parameters.kind,PARAM_NAME:.spec.parameters.name' | sed 's/^/  /'
  ALB_CLASS="$("${KUBECTL[@]}" get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.controller}{"\n"}{end}' 2>/dev/null | grep -i 'alb' | awk '{print $1}' | head -1)"
  if [[ -n "$ALB_CLASS" ]]; then ok "找到 ALB 的 IngressClass：$ALB_CLASS（我们的 Ingress 里应写 ingressClassName: $ALB_CLASS）"
  else no "没有 controller 含 alb 的 IngressClass —— ALB Ingress 组件可能没装"; fi
else
  no "集群里没有任何 IngressClass —— 说明还没装 Ingress 控制器（ALB 或 Nginx）"
fi

line "2) AlbConfig CRD 与实例"
if "${KUBECTL[@]}" get crd 2>/dev/null | grep -qi 'albconfig'; then
  ok "AlbConfig CRD 存在"
  "${KUBECTL[@]}" get albconfigs -A 2>&1 | sed 's/^/  /'
  "${KUBECTL[@]}" get albconfigs -A -o jsonpath='{range .items[*]}  名称={.metadata.name} 实例={.spec.config.id} 地址类型={.spec.config.addressType} 可用区={.spec.config.zoneMappings[*].zoneId}{"\n"}{end}' 2>/dev/null
else
  no "没有 AlbConfig CRD —— ALB Ingress 组件未安装"
fi

line "3) ALB Ingress 控制器"
"${KUBECTL[@]}" get pods -A 2>/dev/null | grep -iE "alb.*ingress|ingress.*alb" | sed 's/^/  /' || no "没找到 ALB Ingress 控制器的 Pod"
  echo
  echo "  组件清单（ACK 控制台 → 运维管理 → 组件管理 里应能看到）："
"${KUBECTL[@]}" get deploy -n kube-system 2>/dev/null | grep -i alb | sed 's/^/    /' || true

line "4) 目标命名空间与现有 Ingress"
"${KUBECTL[@]}" get ns vtf-tools 2>&1 | sed 's/^/  /'
"${KUBECTL[@]}" -n vtf-tools get ingress 2>&1 | sed 's/^/  /'

line "结论与下一步"
cat <<'TIP'
  A. 有 ALB 的 IngressClass（例如 alb）→ 直接 apply manifests/ack/20-ingress.yaml
     如果那个 IngressClass 的名字不是 alb，把 yaml 里的 ingressClassName 改成对应的名字。

  B. 有 AlbConfig 但没有 IngressClass → 建一个指向它（把 <AlbConfig名> 换掉）：

        apiVersion: networking.k8s.io/v1
        kind: IngressClass
        metadata:
          name: alb
        spec:
          controller: ingress.k8s.alibabacloud/alb
          parameters:
            apiGroup: alibabacloud.com
            kind: AlbConfig
            name: <AlbConfig名>

  C. 什么都没有（没有 CRD/控制器/AlbConfig）→ 推荐用控制台创建（会自动生成 AlbConfig + IngressClass）：
      容器服务 ACK 控制台 → 网络 → 路由 → 创建 Ingress → 选择 ALB Ingress →
      选/新建一个 ALB 实例（地址类型、可用区按你的 tools 节点所在可用区选）→ 完成后回本脚本重跑确认。
      注意：ALB 实例的可用区要包含 tools 节点池所在的可用区，否则后端 Pod 加不进去。

  D. 多个 ALB 实例并存时：为每个 AlbConfig 建一个独立的 IngressClass（如 alb-vtf），
     再让我们的 Ingress 用 ingressClassName: alb-vtf，避免误绑到别的实例。
TIP
