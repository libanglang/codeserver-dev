#!/usr/bin/env bash
# 把 Codex 配置部署到开发机的持久化 HOME(/home/coder-profile)：
#   ~/.codex/config.toml            基础配置（model_catalog_json / 信任 /workspace）
#   ~/.codex/deepseek.config.toml   codex --profile deepseek
#   ~/.codex/kimi.config.toml       codex --profile kimi
#   ~/.codex/models.json            自定义模型目录（从本机 ~/.codex/models.json 复制）
#   ~/.codex/env                    密钥（可选，WITH_KEYS=1 时才写）
#
# 用法：
#   bash scripts/10-setup-codex.sh                       # 三台都配（不含密钥）
#   APPS="zk" bash scripts/10-setup-codex.sh             # 只配某一台
#   WITH_KEYS=1 bash scripts/10-setup-codex.sh           # 顺便把当前 shell 里的
#                                                        # DEEPSEEK_API_KEY / KIMI_API_KEY 写进去
#
# 注意：本脚本不会把密钥写进仓库，只写进容器内 $HOME（hostPath，重启不丢，权限 600）。
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl

APPS="${APPS:-lqm yl zk}"
WITH_KEYS="${WITH_KEYS:-0}"
SRC_DIR="${REPO_ROOT}/codex"
HOST_CODEX_DIR="${HOST_CODEX_DIR:-$HOME/.codex}"
CTX="kind-${CLUSTER_NAME}"

[[ -f "$SRC_DIR/config.toml" ]] || die "缺少 $SRC_DIR/config.toml"

# 把本地文件写进容器指定路径（用 stdin，避免 kubectl cp 对非 root 用户的权限问题）
push_file() { # $1=pod $2=本地文件 $3=容器内绝对路径
  local pod="$1" src="$2" dst="$3"
  kubectl --context "$CTX" -n "$NAMESPACE" exec -i "$pod" -- \
    sh -c "mkdir -p \"\$(dirname '$dst')\"; cat > '$dst'" < "$src"
}

for app in $APPS; do
  pod="$(kubectl --context "$CTX" -n "$NAMESPACE" get pod -l "app.kubernetes.io/instance=codeserver-${app}" \
        -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || die "找不到 codeserver-${app} 的 Pod"
  log "配置 codeserver-${app}（pod=${pod}）"

  push_file "$pod" "$SRC_DIR/config.toml"           '/home/coder-profile/.codex/config.toml'
  push_file "$pod" "$SRC_DIR/deepseek.config.toml"  '/home/coder-profile/.codex/deepseek.config.toml'
  push_file "$pod" "$SRC_DIR/kimi.config.toml"      '/home/coder-profile/.codex/kimi.config.toml'

  if [[ -f "$HOST_CODEX_DIR/models.json" ]]; then
    push_file "$pod" "$HOST_CODEX_DIR/models.json" '/home/coder-profile/.codex/models.json'
    log "  已复制自定义模型目录 models.json"
  else
    warn "  本机没有 $HOST_CODEX_DIR/models.json，deepseek-flash / kimi-* 这些自定义模型名可能无法识别"
  fi

  if [[ "$WITH_KEYS" == "1" ]]; then
    if [[ -n "${DEEPSEEK_API_KEY:-}" || -n "${KIMI_API_KEY:-}" ]]; then
      {
        [[ -n "${DEEPSEEK_API_KEY:-}" ]] && printf 'export DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY"
        [[ -n "${KIMI_API_KEY:-}" ]]     && printf 'export KIMI_API_KEY=%s\n' "$KIMI_API_KEY"
      } | kubectl --context "$CTX" -n "$NAMESPACE" exec -i "$pod" -- \
            sh -c 'umask 077; cat > /home/coder-profile/.codex/env; chmod 600 /home/coder-profile/.codex/env'
      # .bashrc 里加一行（幂等），新开的终端自动带上密钥
      kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- sh -c '
        grep -q "\.codex/env" /home/coder-profile/.bashrc 2>/dev/null || \
        printf "\n# codex api keys\n[ -f \"\$HOME/.codex/env\" ] && . \"\$HOME/.codex/env\"\n" >> /home/coder-profile/.bashrc'
      log "  已写入 ~/.codex/env（权限 600，内容不回显）"
    else
      warn "  WITH_KEYS=1 但当前 shell 没有 DEEPSEEK_API_KEY / KIMI_API_KEY，跳过"
    fi
  fi

  # 校验：版本 + 配置文件是否被识别（--strict-config 对未知字段会报错）
  kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- sh -c '
    export PATH=/usr/local/bin:$PATH
    printf "  codex: %s\n" "$(codex --version 2>&1 | tail -1)"
    printf "  ~/.codex: %s\n" "$(ls /home/coder-profile/.codex 2>/dev/null | tr "\n" " ")"
    for p in deepseek kimi; do
      if codex --strict-config -p "$p" exec --help >/dev/null 2>&1; then
        echo "  profile $p: 配置解析 OK"
      else
        echo "  profile $p: 解析失败（用 codex --strict-config -p $p exec --help 看原因）"
      fi
    done'
done

echo
log "用法（在开发机的终端里）："
echo "  codex --profile deepseek        # 用 deepseek-flash"
echo "  codex --profile kimi            # 用 kimi-k2.7-code-highspeed"
echo "  codex                           # 基础配置（默认模型目录照旧）"
echo "  密钥还没写的话：WITH_KEYS=1 DEEPSEEK_API_KEY=xxx KIMI_API_KEY=yyy bash scripts/10-setup-codex.sh"
echo "  想换模型：改 codex/deepseek.config.toml 里的 model（可选值见 models.json 的 slug）"
