#!/bin/sh
# image-selfcheck —— 镜像自检：同一份脚本在本地 kind、阿里云 ACK / ECS 上都能跑，
# 输出稳定的 key=value 行，方便两边逐段 diff。
#
#   [image]    镜像里烧死的内容（构建产物）：两边必须**完全一致**
#   [platform] 运行平台信息：预期会不同
#   [contract] 运行契约：Deployment/Pod 必须提供的东西（uid、HOME、目录）
#   [tools]    工具是否存在与路径
#   [mounts]   挂载/持久化目录：由部署决定，预期不同
#
# 用法： image-selfcheck  （容器内） / docker run --rm <image> image-selfcheck
set -u

section() { printf '\n[%s]\n' "$1"; }

section image
# code-server --version 在"没有配置文件"时会先打一行 info 日志，这里只取版本行
echo "base.code-server=$(code-server --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]+ with Code [0-9.]+' | head -1)"
echo "base.os=$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2);print $2}' /etc/os-release)"
echo "cli.codex=$(codex --version 2>/dev/null | tail -1)"
echo "cli.go=$(go version 2>/dev/null | awk '{print $3}')"
echo "cli.python=$(python3 -V 2>&1)"
echo "cli.node=$(node -v 2>&1)"
echo "cli.npm=$(npm -v 2>&1)"
echo "cli.git=$(git --version 2>&1 | awk '{print $3}')"
echo "cli.kubectl=$(kubectl version --client 2>/dev/null | head -1 | awk '{print $3}')"
echo "cli.podman=$(podman --version 2>&1 | awk '{print $3}')"
echo "cli.buildah=$(buildah --version 2>&1 | head -1 | awk '{print $3}')"
echo "env.GOPROXY=${GOPROXY:-unset}"
echo "env.PIP_INDEX_URL=${PIP_INDEX_URL:-unset}"
echo "env.NPM_CONFIG_REGISTRY=${NPM_CONFIG_REGISTRY:-unset}"
# 用契约路径判断，避免因为 HOME 不同而产生差异
echo "env.PATH_has_contract_bin=$(case ":$PATH:" in *":/home/coder-profile/.local/bin:"*) echo yes;; *) echo no;; esac)"
echo "env.PATH=$(printf '%s' "$PATH" | sed 's|/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|/STD_BINS|')"
echo "storage.driver=$(sed -n 's/^driver *= *"\(.*\)"/\1/p' /etc/containers/storage.conf 2>/dev/null)"
echo "subuid.table=$(awk -F: '/^dev10/{printf "%s=%s ", $1, $2}' /etc/subuid 2>/dev/null)"

section platform
echo "arch=$(dpkg --print-architecture)"
echo "kernel=$(uname -r)"
echo "uid=$(id -u)"
echo "user=$(id -un 2>/dev/null || echo NO_PASSWD_ENTRY)"
echo "home=$HOME"
echo "cwd=$(pwd)"
echo "hostname=$(hostname)"

section contract
for u in 1001 1002 1003; do
  line=$(getent passwd "$u" 2>/dev/null || true)
  if [ -n "$line" ]; then
    printf 'passwd.%s=%s home=%s shell=%s\n' "$u" "$(echo "$line" | cut -d: -f1)" "$(echo "$line" | cut -d: -f6)" "$(echo "$line" | cut -d: -f7)"
  else
    printf 'passwd.%s=MISSING\n' "$u"
  fi
done
printf 'running_uid_has_passwd=%s\n' "$([ -n "$(getent passwd "$(id -u)" 2>/dev/null)" ] && echo yes || echo no)"
printf 'home_matches_contract=%s\n' "$([ "$HOME" = "/home/coder-profile" ] && echo yes || echo no)"
printf 'codex.config=%s\n' "$([ -f "$HOME/.codex/config.toml" ] && echo present || echo absent)"
printf 'ssh.key=%s\n' "$([ -f "$HOME/.ssh/id_ed25519" ] && echo present || echo absent)"

section tools
for c in gcc g++ make cmake python3 pip3 node npm go git codex kubectl podman buildah skopeo ssh ssh-keygen ssh-keyscan rg; do
  p=$(command -v "$c" 2>/dev/null || true)
  printf '%-12s %s\n' "$c" "${p:-MISSING}"
done

section mounts
for d in "$HOME" "$HOME/.local/share/code-server" "$HOME/.local/share/containers" "$HOME/go" "$HOME/.codex" "$HOME/.ssh" /workspace /tmp; do
  if [ -e "$d" ]; then
    printf '%-42s exists=%s writable=%s\n' "$d" yes "$([ -w "$d" ] && echo yes || echo no)"
  else
    printf '%-42s exists=no\n' "$d"
  fi
done
printf 'node.path.visible=%s\n' "$([ -e /data ] && echo yes || echo no)"
echo
