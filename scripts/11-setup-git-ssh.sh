#!/usr/bin/env bash
# 给三台开发机准备 GitHub SSH 访问：
#   - 每台生成 ed25519 密钥（已存在则复用，不覆盖）
#   - 写入 ~/.ssh/known_hosts（免去首次连接的 yes/no 交互）
#   - 写 ~/.ssh/config（22 端口被墙时可用 SSH_PORT=443 走 ssh.github.com:443）
#   - 可选设置 git 提交身份（GIT_NAME / GIT_EMAIL）
#   - 打印每台的公钥，贴到 GitHub 即可
#
# 用法：
#   bash scripts/11-setup-git-ssh.sh
#   GIT_NAME="张三" GIT_EMAIL="zhangsan@example.com" bash scripts/11-setup-git-ssh.sh
#   APPS="zk" bash scripts/11-setup-git-ssh.sh
#   SSH_PORT=443 bash scripts/11-setup-git-ssh.sh        # 公司网络封 22 端口时
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd kubectl

APPS="${APPS:-lqm yl zk}"
SSH_PORT="${SSH_PORT:-22}"
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
CTX="kind-${CLUSTER_NAME}"

if [[ "$SSH_PORT" == "443" ]]; then
  GH_HOST="ssh.github.com"
else
  GH_HOST="github.com"
fi

pubkeys=()

for app in $APPS; do
  pod="$(kubectl --context "$CTX" -n "$NAMESPACE" get pod \
        -l "app.kubernetes.io/instance=codeserver-${app}" -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$pod" ]] || die "找不到 codeserver-${app} 的 Pod"
  log "配置 codeserver-${app}（pod=${pod}）"

  # 1) 生成密钥（幂等：已存在就不动）
  kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- sh -c "
    set -e
    umask 077
    mkdir -p \$HOME/.ssh
    if [ ! -f \$HOME/.ssh/id_ed25519 ]; then
      ssh-keygen -t ed25519 -N '' -C 'codeserver-${app}' -f \$HOME/.ssh/id_ed25519 >/dev/null
      echo '    已生成新密钥 id_ed25519'
    else
      echo '    复用已有密钥 id_ed25519'
    fi
    chmod 600 \$HOME/.ssh/id_ed25519; chmod 644 \$HOME/.ssh/id_ed25519.pub
  "

  # 2) known_hosts（免交互）
  kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- sh -c "
    ssh-keyscan -t ed25519,rsa github.com >> \$HOME/.ssh/known_hosts 2>/dev/null
    sort -u \$HOME/.ssh/known_hosts -o \$HOME/.ssh/known_hosts 2>/dev/null || true
    echo \"    known_hosts: \$(wc -l < \$HOME/.ssh/known_hosts) 条\"
  "

  # 3) ssh config（避免 git 用错 key；443 模式下改走 ssh.github.com）
  printf 'Host github.com\n  HostName %s\n  Port %s\n  User git\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  ServerAliveInterval 30\n' \
    "$GH_HOST" "$SSH_PORT" | kubectl --context "$CTX" -n "$NAMESPACE" exec -i "$pod" -- \
    sh -c 'umask 077; cat > $HOME/.ssh/config; chmod 600 $HOME/.ssh/config'

  # 4) git 提交身份（可选）
  if [[ -n "$GIT_NAME" ]]; then
    kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- git config --global user.name "$GIT_NAME"
  fi
  if [[ -n "$GIT_EMAIL" ]]; then
    kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- git config --global user.email "$GIT_EMAIL"
  fi

  # 5) 连通性自检：没加公钥前应返回 "Permission denied (publickey)" —— 说明网络和 ssh 都正常
  probe="$(kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- \
    sh -c "timeout 25 ssh -o BatchMode=yes -T git@github.com 2>&1 | tail -1")"
  echo "    ssh 连通性: ${probe}"

  key="$(kubectl --context "$CTX" -n "$NAMESPACE" exec "$pod" -- sh -c 'cat $HOME/.ssh/id_ed25519.pub')"
  pubkeys+=("codeserver-${app}|${key}")
done

echo
log "把下面的公钥加到 GitHub → Settings → SSH and GPG keys → New SSH key（每台一把）："
for item in "${pubkeys[@]}"; do
  printf '\n  # %s\n  %s\n' "${item%%|*}" "${item#*|}"
done

cat <<'TIP'

加完之后的验证（在开发机终端里）：
  ssh -T git@github.com          # 期望：Hi <你的用户名>! You've successfully authenticated
  git clone git@github.com:<org>/<private-repo>.git

常用操作：git clone / git pull / git push 都用同一个密钥，无需再输入密码。
TIP

if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
  warn "还没设置 git 提交身份，提交会报 author unknown。补一次："
  echo "    GIT_NAME='你的名字' GIT_EMAIL='你的邮箱' bash scripts/11-setup-git-ssh.sh"
fi
