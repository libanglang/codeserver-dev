#!/usr/bin/env bash
# 症状：浏览器打开 http://codeserver.example.com/... 返回 HTTP ERROR 502，
#       但 WSL 里的 curl 或 Windows 上 curl.exe --noproxy '*' 都正常。
# 原因：Windows 开着系统代理（本机是 127.0.0.1:57890）且绕过列表为空，
#       Chrome/Edge 会把请求交给代理，代理解析/连接不到这个"本机域名"就回 502。
# 处理：把域名加进系统代理绕过列表（HKCU，用户级，不需要管理员）。
# 注意：某些代理软件每次启动会重写系统代理设置，届时重跑本脚本即可。
set -euo pipefail
source "$(dirname "$0")/env.sh"

PS="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
[[ -x "$PS" ]] || die "找不到 $PS（本脚本需要在 WSL 里运行）"

ENTRY="<local>;localhost;127.0.0.1;${INGRESS_HOST}"

# 注意：Windows PowerShell 输出到管道时是 UTF-16LE（带 NUL 字节），
# 所以下面的 PowerShell 输出只用 ASCII，然后统一去掉 NUL 与 CR。
log "设置系统代理绕过列表：$ENTRY"
"$PS" -NoProfile -Command "
\$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
\$s = Get-ItemProperty \$k
Write-Output ('  ProxyEnable       = ' + \$s.ProxyEnable)
Write-Output ('  ProxyServer       = ' + \$s.ProxyServer)
Write-Output ('  ProxyOverride old = [' + \$s.ProxyOverride + ']')
Set-ItemProperty -Path \$k -Name ProxyOverride -Value '${ENTRY}'
Write-Output ('  ProxyOverride new = [' + (Get-ItemProperty \$k).ProxyOverride + ']')
\$p = [System.Net.WebRequest]::GetSystemWebProxy()
Write-Output ('  resolved ${INGRESS_HOST} -> ' + \$p.GetProxy('http://${INGRESS_HOST}/'))
" 2>&1 | tr -d '\r\000' | grep -v '^[[:space:]]*$'

log "上面 resolved 若返回 http://${INGRESS_HOST}/（而不是代理地址）即为直连，浏览器刷新即可（必要时重启浏览器）"
