#!/usr/bin/env bash
# ACR 权限体检：不推镜像，只向 registry 申请带 push 权限的 token，看服务端实际给了什么。
#
# 典型用途：push 报 "insufficient_scope: authorization failed" 时，判断是
#   (a) 没登录 / 密码不对        -> 根本签不出 token
#   (b) 登录了但账号没被授权     -> token 的 access 是空数组 []   ← 最常见
#   (c) 有权限                   -> access 里会出现 repository:<ns>/<repo>:push
#
# 用法：
#   bash scripts/14-acr-doctor.sh                                   # 默认查本仓库的 ACR + vtf 命名空间
#   ACR_REGISTRY=xxx ACR_NAMESPACE=xx ACR_REPO=yy bash scripts/14-acr-doctor.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"

ACR_REGISTRY="${ACR_REGISTRY:-your-acr-registry.cn-hangzhou.cr.aliyuncs.com}"
ACR_USER="${ACR_USER:-<your-acr-username@your-account-id>}"
ACR_NAMESPACE="${ACR_NAMESPACE:-vtf}"
ACR_REPO="${ACR_REPO:-tools/codeserver-dev}"

# --- 取凭据（优先 docker credential helper，其次 ~/.docker/config.json）--------
get_cred() {
  local helper out
  for helper in docker-credential-desktop.exe docker-credential-desktop docker-credential-pass docker-credential-osxkeychain; do
    if command -v "$helper" >/dev/null 2>&1; then
      out="$(printf '%s' "$ACR_REGISTRY" | "$helper" get 2>/dev/null || true)"
      if [[ -n "$out" ]]; then printf '%s' "$out" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["Username"]+"\n"+d["Secret"])'; return 0; fi
    fi
  done
  python3 - "$HOME/.docker/config.json" "$ACR_REGISTRY" <<'PY'
import base64, json, os, sys
path, host = sys.argv[1], sys.argv[2].split("/")[0]
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(0)
for k, v in cfg.get("auths", {}).items():
    if host in k and v.get("auth"):
        print(base64.b64decode(v["auth"]).decode())
        break
PY
}

cred="$(get_cred)" || true
if [[ -z "${cred:-}" ]]; then
  warn "本地找不到 $ACR_REGISTRY 的登录凭据，请先 docker login"
  die  "docker login --username='$ACR_USER' $ACR_REGISTRY"
fi
user="$(printf '%s' "$cred" | sed -n 1p)"
pass="$(printf '%s' "$cred" | sed -n 2p)"

log "registry  : $ACR_REGISTRY"
log "登录身份  : $user"
log "检查目标  : $ACR_NAMESPACE/$ACR_REPO （push + pull）"

challenge="$(curl -s -D - -o /dev/null -m 20 "https://$ACR_REGISTRY/v2/" | tr -d '\r' | grep -i '^www-authenticate' || true)"
realm="$(printf '%s' "$challenge" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
service="$(printf '%s' "$challenge" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
[[ -n "$realm" ]] || die "拿不到认证挑战，registry 是否可达？"
instance="$(printf '%s' "$service" | awk -F: '{print $NF}')"
echo "  认证服务: $realm"
echo "  ACR 实例: $instance"

token="$(curl -s -m 20 -u "$user:$pass" \
  "$realm?service=$(printf '%s' "$service" | sed 's/:/%3A/g')&scope=repository:$ACR_NAMESPACE/$ACR_REPO:push,pull" \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("token",""))
except Exception: print("")')"
[[ -n "$token" ]] || die "服务端拒绝签发 token（账号或密码不对）"

python3 - "$token" "$ACR_NAMESPACE/$ACR_REPO" <<'PY'
import base64, json, sys
tok, repo = sys.argv[1], sys.argv[2]
pl = tok.split(".")[1]; pl += "=" * (-len(pl) % 4)
d = json.loads(base64.urlsafe_b64decode(pl))
access = d.get("access") or []
print("  服务端授予:", access or "[]（空 = 这个账号在该实例里没有任何权限）")
if not access:
    print("\n  ✗ 结论：登录成功但未授权。需要公司主账号/ACR 管理员给这个 RAM 用户授权：")
    print("      - 方式1：RAM 控制台 → 用户 → 添加权限 → AliyunContainerRegistryFullAccess（或自定义 cr:* 策略）")
    print("      - 方式2：ACR 企业版实例 → 访问控制 → 给该 RAM 用户授予实例/命名空间的读写权限")
    print("      - 并确认命名空间存在：", repo.split('/')[0])
    sys.exit(1)
for entry in access:
    acts = entry.get("actions", [])
    print(f"    {entry.get('type')}:{entry.get('name')} -> {acts}")
if any("push" in a for e in access for a in e.get("actions", [])):
    print("\n  ✓ 结论：该账号对这个仓库有 push 权限，可以推送")
else:
    print("\n  ⚠ 结论：只有部分权限（没有 push），仍推不上去")
    sys.exit(1)
PY
