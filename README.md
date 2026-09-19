# kind + code-server 开发集群（Windows 11 / WSL2 本地环境）

本文档与当前机器上**已经跑起来并实测通过**的环境一一对应，不是纸面方案。

```
kind 集群 vtf-dev（Kubernetes v1.36.4）
├── vtf-dev-control-plane  ingress-ready=true，宿主 80 端口映射到它
├── vtf-dev-worker         标签 vtf.io/worker=worker01
└── vtf-dev-worker2        标签 vtf.io/worker=worker02  ← 三台 code-server 都在这里
        ├── codeserver-lqm  hostPath /data/group/vtf/lqm
        ├── codeserver-yl   hostPath /data/group/vtf/yl
        └── codeserver-zk   hostPath /data/group/vtf/zk
```

| 需求 | 实现 | 状态 |
| --- | --- | --- |
| K8s v1.36，1 控制面 + 2 worker | `kindest/node:v1.36.4`（kind v0.33.0 为 1.36 发布的最新 patch） | 实测 v1.36.4 三节点 Ready |
| Windows 用 Lens 管集群 | API Server 固定 `127.0.0.1:6443`，kubeconfig 已拷到 Windows | Windows 侧访问 `/version` 返回 200 |
| worker02 上三台 code-server | `nodeSelector: vtf.io/worker=worker02` | 三个 Pod 均 Running 于 worker02 |
| hostPath 挂载 | 节点上 `/data/group/vtf/{lqm,yl,zk}`（各自 uid、0700），容器内统一挂到 `/workspace` | 各自可读写、互相访问被拒、容器内看不到节点路径，实测 OK |
| 域名 + 路径访问 | ingress-nginx 前缀剥离 + 301 补斜杠 | 三条路径实测 301/302/登录/静态资源全部正常 |

## 0. 这台机器的现状（我实测出来的）

| 项 | 实际值 |
| --- | --- |
| WSL 发行版 | **Ubuntu-24.04**（不是 22.04；Docker Desktop 的 WSL 集成里也只勾了 24.04） |
| kind / kubectl | `~/.local/bin/kind` v0.33.0、`~/.local/bin/kubectl` v1.36.4 |
| Docker Desktop | 已启动，镜像/网络走 Windows 侧（WSL 内直接 `curl` 走 IPv6 会超时，脚本已统一 `curl -4`） |
| 80 端口 | 空闲，已由 kind 的控制面节点映射 |
| 443 端口 | 被 **VMware Workstation Server（`vmware-hostd`）** 占用 → 本方案只走 HTTP，不映射 443 |

## 1. 现在就能用的三件事

### 1.1 浏览器访问（Windows）

先加 hosts（**管理员 PowerShell**，这是唯一需要你手动做的一步）：

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1  codeserver.example.com"
ipconfig /flushdns
```

然后打开（结尾斜杠必须有，不带斜杠会自动 301 跳过去，两种都行）：

```
http://codeserver.example.com/dev/group/vtf/lqm/
http://codeserver.example.com/dev/group/vtf/yl/
http://codeserver.example.com/dev/group/vtf/zk/
```

登录密码（**三台各自独立**，定义在 `manifests/05-codeserver-passwords.yaml`）：

| 开发机 | 节点上的目录（hostPath） | 容器内目录 | 密码 |
| --- | --- | --- | --- |
| codeserver-lqm | `/data/group/vtf/lqm` | `/workspace` | `CHANGE_ME_lqm` |
| codeserver-yl | `/data/group/vtf/yl` | `/workspace` | `CHANGE_ME_yl` |
| codeserver-zk | `/data/group/vtf/zk` | `/workspace` | `CHANGE_ME_zk` |

> 同一个浏览器登录三台时，Chrome 可能把上一次保存的密码自动填充到另外两台的登录页（因为是同一个域名/origin），
> 这时要手动改成对应那一台的密码。

### 1.2 Lens 管理集群

kubeconfig 已经写好并拷到 Windows：

```
C:\Users\<user>\.kube\config             ← Lens 默认读这个
C:\Users\<user>\.kube\kind-vtf-dev.yaml  ← 也可以用它 Add Cluster
```

`server: https://127.0.0.1:6443`，Docker Desktop 已把该端口转发到 Windows，**不要改成别的地址**。
集群重建后必须重新执行 `bash scripts/05-export-kubeconfig.sh`（客户端证书会变）。

### 1.3 命令行

```bash
export PATH="$HOME/.local/bin:$PATH"     # 建议写进 ~/.bashrc
kubectl get nodes -L vtf.io/worker
kubectl -n dev get pods -o wide

# 日常：进容器 / 进节点 / 看日志
kubectl -n dev exec -it deploy/codeserver-lqm -- bash
docker exec -it vtf-dev-worker2 bash
kubectl -n dev logs deploy/codeserver-yl -f
```

## 2. 从零重来（集群已被删除时）

```bash
cd ~/work/code/src/codeserver
export PATH="$HOME/.local/bin:$PATH"

bash scripts/00-install-tools.sh      # kind + kubectl（幂等；注意别中途 Ctrl-C，会留下半截文件）
bash scripts/01-create-cluster.sh     # 1 控制面 + 2 worker，v1.36.4
bash scripts/03-install-ingress.sh    # ingress-nginx + 强制钉到控制面
bash scripts/02-prepare-worker02.sh   # 建 hostPath 目录，各自 chown 到独立 uid 并设 0700
bash scripts/04-deploy-codeserver.sh  # 三台 code-server + Ingress
bash scripts/05-export-kubeconfig.sh  # 导出 kubeconfig 给 Lens
bash scripts/06-verify.sh             # 端到端自检
```

或者一把梭：`bash scripts/all.sh`

Docker Desktop / Windows 重启后（集群没删、只是停了）：

```bash
bash scripts/07-start-cluster.sh      # 拉起三个节点容器并等 Ready，不用重建
```

## 3. 关键技术点（都是踩过的坑，改动前请先读）

### 3.1 K8s 版本：v1.36.4，不是 v1.36.0

kind 的本质是"节点镜像即 K8s 版本"，而 kind 只为部分 patch 版本发布镜像。
`kindest/node:v1.36.0` **不存在**（会报 `not found`）。kind v0.33.0 发布的镜像是：

```
v1.37.0 / v1.36.4 / v1.35.8 / v1.34.11
```

所以 `kind/kind-cluster.yaml` 里写的是：

```yaml
image: kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed
```

`@sha256` 是 kind 官方要求的写法（保证拿到的是该 release 构建的镜像，而不是同名被覆盖的 tag）。
想换版本：改这个 image，然后 `bash scripts/99-teardown.sh` + `scripts/01-create-cluster.sh`。

### 3.2 节点命名：kind 不支持自定义节点名

kind 的节点名固定是 `<集群名>-control-plane` / `-worker` / `-worker2`。所以"worker01 / worker02"用标签表达：

| 你的叫法 | 实际节点名 | 标签 |
| --- | --- | --- |
| 控制节点 | `vtf-dev-control-plane` | `ingress-ready=true` |
| worker01 | `vtf-dev-worker` | `vtf.io/worker=worker01` |
| worker02 | `vtf-dev-worker2` | `vtf.io/worker=worker02` |

标签是通过节点的 `kubeadmConfigPatches → kubeletExtraArgs.node-labels` 在 join 时打上的
（因此节点一注册就带标签），`scripts/01` 里还有一次幂等的 `kubectl label --overwrite` 兜底。
三个 code-server 用 `nodeSelector: vtf.io/worker=worker02` 钉在 worker02。

### 3.3 端口：只映射 80，因为 443 被 VMware 占用

第一次创建时失败在：

```
docker: Error response from daemon: ports are not available: exposing port TCP 0.0.0.0:443
```

查下来是 Windows 上 `vmware-hostd`（VMware Workstation Server 服务，PID 7644）在监听 443。
你的需求是 `http://`，所以 `kind/kind-cluster.yaml` 里只保留 80 的映射，443 被注释掉并写了说明。

以后要上 HTTPS 二选一：

* 停掉 VMware Workstation Server（`Stop-Service VMWareHostd`，需管理员），再把 443 映射放开；
* 或映射到别的宿主端口（如 8443），给 Ingress 加 TLS 证书。

### 3.4 ingress-nginx：必须钉到带 80 映射的那个节点

新版 kind 适配清单（`.../deploy/static/provider/kind/deploy.yaml`）里的 controller
**只写了 `nodeSelector: kubernetes.io/os=linux`**，不再固定 `ingress-ready=true`，
结果控制器会随机落到没有 80 端口映射的 worker 上，浏览器就访问不到。

`scripts/03-install-ingress.sh` 里加了一步 patch 强制钉住：

```bash
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"}}}}}'
```

### 3.5 code-server 的子路径：没有 `--base-path` 了

实测镜像 `codercom/code-server:latest` = **4.137.0**，它**没有** `--base-path` 参数
（只有 `--abs-proxy-base-path`，那是给端口代理用的）。用 `--base-path` 会直接
`error ... ` 并 CrashLoopBackOff。

官方文档（`docs/guide.md`）给出的子路径做法是**在代理层剥离前缀**，Caddy 的例子：

```
mydomain.com/code/* { uri strip_prefix /code ; reverse_proxy 127.0.0.1:8080 }
```

等价的 ingress-nginx 写法（`manifests/20-ingress.yaml`）：

```yaml
annotations:
  nginx.ingress.kubernetes.io/use-regex: "true"
  nginx.ingress.kubernetes.io/rewrite-target: /$1
paths:
  - path: /dev/group/vtf/lqm/(.*)      # $1 就是剥掉前缀后的剩余路径
    pathType: ImplementationSpecific
```

两个必须注意的细节：

1. **结尾斜杠**：code-server 页面里的静态资源和 WebSocket 都是相对路径
   （实测：`href="./_static/..."`、WS 用 `location.pathname + "/" + ...` 拼）。
   浏览器地址若没有结尾 `/`，相对路径会解析错。所以另建了三个 redirect Ingress，
   把 `/dev/group/vtf/lqm` **301** 到 `/dev/group/vtf/lqm/`
   （主正则故意写成要求 `/` 结尾，否则 nginx 正则 location 按出现顺序优先，会抢在 redirect 前面）。
2. **cookie 隔离**：三台共用 `codeserver.example.com` 这一个 origin，
   cookie 默认同名会互相覆盖，所以每台加了 `--cookie-suffix=-lqm/-yl/-zk`，
   实测 cookie 名为 `code-server-session--lqm` / `--yl` / `--zk`。
   注意参数必须写成 `--cookie-suffix=-lqm`，写成 `--cookie-suffix -lqm` 会因为
   `-lqm` 被当成新选项而报 `--cookie-suffix requires a value`。
   另外**三台密码必须不同**：同一个 origin 下浏览器（Chrome 密码管理器）会把同一个域名的密码
   自动填充到三台的登录页，密码又都一样的话就出现"没输密码就进去了"的错觉；
   密码不同时，自动填充的错误密码会被服务端拒绝，逼你填对应那一台的正确密码。

### 3.6 hostPath 与目录权限

* hostPath 路径在**节点容器的文件系统**里（见第 6 节的数据持久化说明）。
* **隔离第一层（结构性）**：hostPath 是**逐目录 bind mount**。三个 Pod 各挂 `/data/group/vtf/<name>`，
  容器里 `/data/group/vtf` 下**只能看到自己那一份**，别人的目录连名字都不存在。
  实测：lqm 容器里 `ls /data/group/vtf` 只有 `lqm`，访问 `yl`/`zk` 报 `No such file or directory`。
* **隔离第二层（权限）**：三台用**不同的 uid**（lqm=1001、yl=1002、zk=1003），
  节点上每个目录属主=对应 uid、权限 `0700`；父目录 `/data/group/vtf` 本身 root 所有 `0711`。
  ⚠️ 如果三台都用 uid 1000，即使目录是 0700 也挡不住：它们对彼此的目录都算"属主"，权限位直接放行
  —— 这正是最初"从一台能改另一台文件"的根因。
  `scripts/02-prepare-worker02.sh` 负责 `mkdir + chown <uid>:<uid> + chmod 700`。
* **容器内路径故意改名为 `/workspace`**：hostPath 的"节点路径"和"容器内挂载点"是两回事。
  若按节点原路径挂（`/data/group/vtf/<name>`），容器里就存在 `/data/group/vtf` 这条路径，
  用户能在"打开文件夹"里往上翻到 `/data`、`/data/group`（只读，但会看到整个目录结构，
  甚至看到同层别人的目录名）。改成挂到独立的 `/workspace` 后，容器内**根本没有 `/data`**：

  ```yaml
  volumeMounts:
    - name: workspace
      mountPath: /workspace          # 容器内路径（用户看到的、能写的）
  volumes:
    - name: workspace
      hostPath:
        path: /data/group/vtf/lqm    # 节点上的真实数据位置，没有变
  ```

  于是 URL 也变短：`.../lqm/?folder=/workspace`。
* uid 不是 1000 时**镜像里的 `/home/coder` 不可写**，所以把 HOME 指到挂载出来的 profile 目录
  （`HOME=/home/coder-profile`）。实测 uid=1001 下 code-server 启动、登录、终端全部正常。
* 不要设 `fsGroup`：kubelet 会对 hostPath 递归 chown，可能破坏上面的属主隔离。
* hostPath 用 `type: Directory`（不是 `DirectoryOrCreate`）：目录不存在就明确报错，
  避免 kubelet 建出 root:root 的空目录让人一头雾水。
* `strategy: Recreate`：hostPath 是独占语义，避免滚动更新时两个 Pod 同时写同一份代码。
* 每台的 profile 目录 `/data/group/vtf/.codeserver/<name>`（同样 0700 + 各自 uid）挂到
  `/home/coder-profile`，这样 Pod 重建后扩展和设置不丢。
* `VSCODE_PROXY_URI=./proxy/{{port}}`：让端口转发面板生成相对链接，配合前缀剥离才能用。

## 4. 实测记录（这套东西凭什么说"能用"）

```
节点        vtf-dev-control-plane / vtf-dev-worker / vtf-dev-worker2  全部 Ready，v1.36.4
标签        vtf.io/worker=worker01 / worker02，控制面 ingress-ready=true
Pod         三个 code-server 都 Running 在 vtf-dev-worker2
隔离        容器内只有 /workspace（自己的工作目录，可读写）+ 只读的系统目录；/data 在容器内不存在；
            别人的目录不可见；uid 1001/1002/1003 + 目录 0700 作为第二层
Ingress     无斜杠 /dev/group/vtf/lqm  -> 301 http://codeserver.example.com/dev/group/vtf/lqm/
            带斜杠 /dev/group/vtf/lqm/ -> 302 Location: ./login（应用收到的是 /，说明前缀剥离生效）
登录        三台密码 CHANGE_ME_lqm / CHANGE_ME_yl / CHANGE_ME_zk 各自有效，用 CHANGE_ME_lqm 登 yl、zk 均被拒（不下发 cookie）
            cookie 名 code-server-session--lqm / --yl / --zk，登录后分别跳
            ./?folder=/data/group/vtf/lqm | /yl | /zk（各开各的目录）
页面        跟随跳转后 200，4384 字节，含 workbench
静态资源    .../dev/group/vtf/lqm/stable-<hash>/static/out/vs/code/browser/workbench/workbench.js
            -> 200，1057216 字节（证明子路径下相对资源可用）
WebSocket   前端源码用 (location.pathname + "/" + t) 拼地址 => 子路径下终端/WS 可用
Windows     从 Windows 侧 curl http://127.0.0.1/dev/group/vtf/lqm/ -> 302（端口转发链路通）
            curl -k https://127.0.0.1:6443/version -> 200（Lens 链路通）
```

## 5. Windows 侧配置细节

### 5.1 hosts

```powershell
# 管理员权限运行
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1  codeserver.example.com"
ipconfig /flushdns
```

坑：

* `example.com` 是真实域名，如果公共 DNS 上有 A 记录，正常情况 hosts 优先；
  若 Chrome/Edge 开了「使用安全 DNS（DoH）」，可能绕过 hosts，去设置里关掉再试。
* 想让**局域网其他机器/手机**也能访问：Docker Desktop 的端口发布是绑在 Windows 的 0.0.0.0 上的，
  在那些设备上把域名解析到 **Windows 的局域网 IP**，并放行 Windows 防火墙 80 端口即可。

### 5.2 Lens

`C:\Users\<user>\.kube\config` 已经写好，Lens 启动后会直接看到 `kind-vtf-dev` 集群；
也可以 `Add Cluster` 选 `kind-vtf-dev.yaml`。排错：

```powershell
Test-NetConnection 127.0.0.1 -Port 6443
```

不通就是 Docker Desktop 没启动 / 集群被删了（`kind get clusters` 确认）。

### 5.3 系统代理会把域名截走（实测踩过的坑）

本机开着系统代理 `127.0.0.1:57890`（`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`
里 `ProxyEnable=1`），而绕过列表 `ProxyOverride` 是空的。结果：

```
浏览器（跟随系统代理）      http://codeserver.example.com/dev/group/vtf/lqm/  -> 502 Bad Gateway
绕过代理（curl --noproxy）  同一个地址                                            -> 302（正常）
```

Chrome/Edge 默认跟随系统代理，所以要把域名加进绕过列表：

```bash
bash scripts/08-fix-windows-proxy.sh
```

等价的注册表值（HKCU，用户级，不需要管理员）：

```
ProxyOverride = <local>;localhost;127.0.0.1;codeserver.example.com
```

判定是否生效（返回域名本身=直连；返回 `127.0.0.1:57890`=仍走代理）：

```powershell
[System.Net.WebRequest]::GetSystemWebProxy().GetProxy("http://codeserver.example.com/")
```

另外地址栏里**要把 `http://` 写全**：只输入域名时 Chrome 会先试 `https://`（443），
而 443 被 VMware Workstation Server 占着，会得到 403 或证书错误。
建议直接收藏 `http://codeserver.example.com/dev/group/vtf/lqm/`。

⚠️ 代理软件（本机是 `go_wails`，监听 57890）重启或切换配置时可能重写系统代理设置，
绕过列表被清掉就重跑一次上面的脚本；能改代理软件自己的"直连/绕过"列表会更稳妥。

## 6. 数据放哪里（重要）

hostPath 的路径在**节点容器**里，即：

```
Pod 的 /data/group/vtf/lqm  ==  vtf-dev-worker2 容器里的 /data/group/vtf/lqm（overlay 层）
```

因此 `kind delete cluster` 会把这三个目录一起删掉。两种做法：

* **方案 A（当前，`kind/kind-cluster.yaml`）**：纯 hostPath，贴合你的原始需求，适合验证/一次性环境。
* **方案 B（推荐长期用，`kind/kind-cluster-hostdata.yaml`）**：给 worker02 加 `extraMounts`，
  把节点容器里的 `/data` 映射到 WSL 真实目录（默认 `/home/<user>/vtf-data`）：

  ```bash
  mkdir -p ~/vtf-data
  KIND_CONFIG=~/work/code/src/codeserver/kind/kind-cluster-hostdata.yaml bash scripts/01-create-cluster.sh
  ```

  Pod 里的 hostPath 写法完全不变，但数据落在 WSL 磁盘，删集群也不丢。
  也可以把 hostPath 指到 Windows 盘（`/mnt/d/...`），但读写走 9p，性能差，建议放 WSL 内部目录。

先备份再删（方案 A）：

```bash
docker cp vtf-dev-worker2:/data/group/vtf ./vtf-data-backup
```

## 7. 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| `docker: could not be found in this WSL 2 distro` | Docker Desktop 没启动，或没给当前发行版开 WSL 集成（本机是 Ubuntu-24.04） |
| 创建集群报 `ports are not available ... :443` | Windows 上 443 被占用（本机是 VMware Workstation Server），保持 443 注释即可 |
| `kind create` 报 image `not found` | 版本 tag 不存在，见 3.1，用 v1.36.4 |
| Pod 一直 Pending | `vtf.io/worker=worker02` 标签没打上：`kubectl get nodes -L vtf.io/worker` |
| `hostPath type check failed: ... is not a directory` | 先跑 `scripts/02-prepare-worker02.sh` |
| 容器里存不了文件 / 目录只读 | 节点目录属主没对上该实例的 uid：`docker exec vtf-dev-worker2 ls -ln /data/group/vtf`，然后重跑 `scripts/02-prepare-worker02.sh` |
| 打开第二台"没输密码就进去了" | 同一 origin 下 Chrome 自动填充了上一台的密码。三台密码已分别设为 CHANGE_ME_lqm/CHANGE_ME_yl/CHANGE_ME_zk，看到自动填充就改掉再登录；也可以在 Chrome 密码管理器里删掉这个站点的保存记录 |
| 从一台能读写另一台的目录 | 隔离被破坏：确认三台的 `runAsUser` 是 1001/1002/1003、目录 `0700` 属主各自 uid，且没有把父目录 `/data/group/vtf` 整棵挂进去（`scripts/06-verify.sh` 会逐项检查） |
| 登录后跳到了 `?folder=/`（打开的是容器根目录而不是工作目录） | 「上次打开的目录」状态被写脏。**权威文件是 `$HOME/.local/share/code-server/coder.json`**（`~/coder.json` 不是生效的那个）。修法：<br>`kubectl -n dev exec deploy/codeserver-zk -- sh -c 'printf "{\n  \"query\": {\n    \"folder\": \"/workspace\"\n  }\n}\n" > $HOME/.local/share/code-server/coder.json'`<br>然后 `kubectl -n dev rollout restart deploy/codeserver-zk`。（起因通常是浏览器在同源下把 `/` 当工作目录打开过一次，code-server 就把这个状态记下来了） |
| 地址栏里的 `?folder=/workspace` 是什么 | code-server 正常行为：登录后 302 到 `./?folder=<工作目录>`，VS Code Web 用这个查询参数表示当前打开的文件夹。它是可写的那个目录，不是泄露路径 |
| 用户还能在"打开文件夹"里翻到 `/etc`、`/usr` 等 | 这是容器自身的文件系统（只读）。code-server 没有"文件系统牢笼"能力，终端同样能看到整个容器；现在已把可写范围限制为 `/workspace`（+ 该实例私有的 `/home/coder-profile`）。要更严格只能上 read-only rootfs / 额外沙箱方案 |
| 容器 `unknown option '--base-path'` | 别再用 `--base-path`，见 3.5 |
| `--cookie-suffix requires a value` | 必须写 `--cookie-suffix=-lqm`（`=` 形式） |
| 页面 404 | 前缀剥离失效：确认 `use-regex` + `rewrite-target` 生效，跑 `scripts/06-verify.sh` |
| 页面样式错乱 / 资源 404 | 地址少了结尾 `/`，用带斜杠的 URL（会自动 301） |
| 访问不到、Pod 正常 | ingress 控制器不在控制面节点上：见 3.4，重新 patch nodeSelector |
| 浏览器报 **HTTP ERROR 502**，但命令行 curl 正常 | Windows 系统代理截走了请求：见 5.3，跑 `bash scripts/08-fix-windows-proxy.sh` |
| 浏览器报 403 / 证书错误 | 地址栏默认先试 HTTPS(443)，而 443 是 VMware Workstation Server：见 3.3，URL 要写全 `http://` |
| `kubectl apply -f https://...` 卡住 | WSL 的 IPv6 问题，命令加 `curl -4` 或换用本仓库的脚本 |
| 下载工具时卡死 | 别中途 Ctrl-C：残留的 curl 会占着文件导致后面对 binary 报 `Text file busy`（`ps -ef \| grep curl` 杀掉重下） |

## 8. 目录结构

```
codex/
  config.toml                  # Codex 基础配置（注入到开发机 ~/.codex/）
  deepseek.config.toml         # codex --profile deepseek
  kimi.config.toml             # codex --profile kimi
image/
  Dockerfile                   # 开发机镜像：工具链 + 国内 apt 源（由 scripts/09 构建）
  selfcheck.sh                 # 镜像内置自检 image-selfcheck（本地/ACK 可直接 diff）
kind/
  kind-cluster.yaml            # 方案 A：1 控制面 + 2 worker，v1.36.4，映射 80（443 已注释）+ 6443
  kind-cluster-hostdata.yaml   # 方案 B：额外把 worker02 的 /data 落到 WSL 真实目录
  ingress-nginx-values.yaml    # 可选：用 Helm 装 ingress-nginx 的 values
manifests/
  00-namespace.yaml            # namespace dev
  05-codeserver-passwords.yaml # 三台各自的密码（Secret，stringData 明文，方便本地改）
  10-codeserver-apps.yaml      # 3 x (Deployment + Service)：hostPath + nodeSelector=worker02
  20-ingress.yaml              # 前缀剥离路由 + 三条 301 补斜杠规则
  30-buildkitd.yaml            # 可选：BuildKit 构建服务（让开发机容器里能构建镜像）
scripts/
  env.sh                       # 公共变量（集群名/版本/域名/节点名）
  00-install-tools.sh          # kind + kubectl（+可选 helm），统一 curl -4
  01-create-cluster.sh         # 建集群 + 打 worker01/worker02 标签
  02-prepare-worker02.sh       # 建 hostPath 目录，chown 到各自 uid 并 chmod 700
  03-install-ingress.sh        # ingress-nginx + 钉到 ingress-ready 节点
  04-deploy-codeserver.sh      # 三台各自的密码 Secret + 三台 code-server + Ingress
  05-export-kubeconfig.sh      # 导出 kubeconfig 并拷到 Windows
  06-verify.sh                 # 端到端自检
  07-start-cluster.sh          # Docker Desktop 重启后恢复集群
  08-fix-windows-proxy.sh      # 修复浏览器走系统代理导致 502
  09-build-image.sh            # 构建开发机镜像 + 载入 kind + 切换三台
  10-setup-codex.sh            # 把 Codex 配置/密钥注入三台开发机
  11-setup-git-ssh.sh          # 生成 GitHub SSH 密钥/known_hosts/config 并打印公钥
  12-verify-image-parity.sh    # 校验本地与集群用的是同一份镜像内容
  99-teardown.sh               # 删集群（会二次确认）
  all.sh                       # 全流程
kind-vtf-dev.yaml              # 导出的 kubeconfig（已 gitignore）
```

参数集中在 `scripts/env.sh`，可临时覆盖：

```bash
CLUSTER_NAME=dev1 INGRESS_HOST=codeserver.example.com bash scripts/01-create-cluster.sh
```

## 9. 在开发机里装依赖 / 编译代码

### 9.1 先分清：哪里可写、哪里会丢

实测（在 Pod 里各放一个文件，然后删掉 Pod 重建，再看还在不在）：

| 位置 | 可写 | Pod 重建后 | 说明 |
| --- | --- | --- | --- |
| `/workspace` | ✅ | **保留** | 你的代码，落在节点 `/data/group/vtf/<name>` |
| `$HOME` = `/home/coder-profile` | ✅ | **保留** | `pip install --user`、npm 全局包、`~/.m2`、`~/go`、`~/.cargo`、各种缓存都在这里 |
| `/tmp`、`/var/tmp` | ✅ | 丢失 | 编译中间产物随便放 |
| `/usr`、`/etc`、`/opt`、`/home/coder` | ❌ | — | 非 root，装不了系统级东西（这正是隔离想要的效果） |

结论：**用户级依赖和缓存放 `$HOME` 就能持久化**；系统级依赖必须打进镜像。

### 9.2 官方镜像里什么工具都没有（实测）

```
gcc g++ cc make cmake python3 pip3 java javac mvn gradle go rustc cargo node npm pnpm yarn  -> 全部没有
git curl wget tar                                                                          -> 只有这些
```

code-server 自己用的 node 打包在 `/usr/lib/code-server/lib/node`，没进 PATH，终端里用不了。
所以**直接在这个镜像里编译是做不到的**，`apt-get install` 也不行（`/usr` 不可写、没有 root）。

### 9.3 正确做法：自建开发机镜像（仓库已备好）

```bash
# 默认：build-essential + cmake + python3/pip/venv + node20/npm + 常用工具
bash scripts/09-build-image.sh

# 需要 Java / Go / Rust：
WITH_JAVA=1 WITH_GO=1 WITH_RUST=1 bash scripts/09-build-image.sh

# 只构建不动集群：
LOAD=0 SWITCH=0 bash scripts/09-build-image.sh
```

脚本做的事：`docker build image/` → `kind load docker-image`（三个节点都载入）→
`kubectl set image` 把三台切过去 → 打印工具链自检。

实测（本机，默认参数构建）：

```
镜像 2.69GB；gcc g++ make cmake python3 pip3 node npm git kubectl 全部就位
C      gcc -O2 hello.c && ./hello                        -> C-compile-OK
C++    g++ -x c++                                        -> 编译运行通过
Python python3 -m venv .venv && pip install requests      -> OK (requests 2.34.2)
Node   npm install lodash && node -e require              -> OK (lodash 4.18.1)
```

镜像内版本（Debian 13）：python 3.13 / node 20.19 / npm 9.2 / cmake 3.31；
可选的 openjdk 21 + maven 3.9 / go 1.24 / rustc+cargo 1.85。

两个注意点：

1. **国内网络必须用国内源**：实测 `deb.debian.org` 只有 ~400KB/s 且反复超时（162MB 下了 6 分 41 秒还没完，构建直接失败）。
   `image/Dockerfile` 默认已改走阿里云源，`--build-arg APT_MIRROR=...` 可换回官方或改用清华/中科大。
2. **切完镜像记得改清单**：`LOAD/SWITCH` 只改运行中的 Deployment，
   `manifests/10-codeserver-apps.yaml` 里的 `image:` 也要改，否则下次 `apply` 会退回旧镜像。

### 9.4 缓存与资源建议

* 用户级依赖放 `$HOME`（镜像里已配好 `npm_config_prefix`、`GOPATH`、`GOMODCACHE`、`CARGO_HOME`、`PIP_CACHE_DIR` 全指向 `$HOME` 下），Pod 重建不丢，重装也不用重新下载。
* Python 建议用 venv（`python3 -m venv /workspace/.venv`）；镜像里已去掉 Debian 的 PEP668 标记，`pip install --user` 也可用。
* 编译吃资源：Pod 当前 `limits: cpu 2 / memory 4Gi`，Docker Desktop 虚拟机是 18 vCPU / 15.4GiB。
  编译大项目建议把 limits 提到 `cpu: 6 / memory: 8Gi`（改 `manifests/10-codeserver-apps.yaml` 后重新 apply）。
* 镜像与缓存都在 Docker Desktop 虚拟机磁盘上（本机在 `D:\app\docker-disk`），注意该盘剩余空间。

### 9.5 内置 Codex CLI（deepseek / kimi 两个 profile）

镜像里已自带 **codex-cli 0.155.1**，装在 `/usr/local`（刻意不装进 `$HOME`——运行时会话的 HOME
被持久化目录覆盖，装在 HOME 里的东西会被盖住看不见）。

配置由 `scripts/10-setup-codex.sh` 注入到开发机的持久化 HOME：

```
~/.codex/config.toml            基础配置：model_catalog_json、信任 /workspace
~/.codex/deepseek.config.toml   codex --profile deepseek
~/.codex/kimi.config.toml       codex --profile kimi
~/.codex/models.json            自定义模型目录（deepseek-flash / kimi-k2.7-code 等 slug）
~/.codex/env                    密钥（可选，权限 600）
```

```bash
bash scripts/10-setup-codex.sh                    # 只放配置（推荐先这样）
APPS="zk" bash scripts/10-setup-codex.sh          # 只配某一台
WITH_KEYS=1 bash scripts/10-setup-codex.sh        # 顺带把当前 shell 的密钥写进去
# 密钥来源是当前 shell 的 DEEPSEEK_API_KEY / KIMI_API_KEY，只写进容器（600 权限），不进仓库
```

在开发机终端里：

```bash
codex --profile deepseek     # deepseek-flash
codex --profile kimi         # kimi-k2.7-code-highspeed
codex                        # 基础配置（默认模型目录）
```

原理：`codex -p/--profile <name>` 会把 `$CODEX_HOME/<name>.config.toml` **叠加**在基础
`config.toml` 之上（见 `codex --help`），所以两个供应商互不干扰、随时切换；
provider 用 `env_key` 引用**环境变量名**，密钥既不进配置文件也不进仓库。
换模型就改 `codex/deepseek.config.toml` 里的 `model`（可选值见 `models.json` 的 slug）。

实测：

```
codex-cli 0.155.1；deepseek/kimi 两个 profile 用 --strict-config 解析全部通过
codex doctor: 17 ok / 1 fail（fail 是 auth —— 因为还没写密钥）
  └─ websocket 那条 warning 实际返回 401 "Missing bearer authentication"，
     说明 api.openai.com 网络是通的，只是没有凭证
```

实测（无密钥状态下能验证的部分）：

```
cd /workspace && codex --profile deepseek exec --skip-git-repo-check "say hi"
  -> OpenAI Codex v0.155.1 / workdir: /workspace / model: deepseek-flash   ← 配置生效
  -> warning: Codex could not find bubblewrap on PATH ... Codex will use the bundled bubblewrap
  -> ERROR: Missing environment variable: `DEEPSEEK_API_KEY`               ← 唯一的阻塞就是密钥
```

两点说明：

* **沙箱**：容器里没有系统 `bubblewrap`，codex 会自动改用**自带**的 bubblewrap，所以沙箱仍可用；
  真遇到沙箱报错时，开发机本身已经是隔离环境，可以直接用
  `codex --sandbox danger-full-access` 或 `--dangerously-bypass-approvals-and-sandbox`。
* **非交互模式**：`codex exec` 要求当前目录是 git 仓库，否则要加 `--skip-git-repo-check`
  （上面的实测就加了这个 flag）。交互式 `codex` 没有这个限制。

### 9.6 Git / GitHub：clone、pull、push（SSH）

**症状**：在开发机里执行 `ssh-keygen` 报

```
No user exists for uid 1003
```

生成不了密钥，`ssh` 本身也一样失败——git 走 SSH 自然也用不了。

**根因**：三台开发机为了做目录隔离，分别以 uid **1001/1002/1003** 运行，
而基础镜像的 `/etc/passwd` 里只有 `coder(1000)`。OpenSSH 的 `ssh` / `ssh-keygen`
需要 `getpwuid` 能查到当前 uid，查不到就直接退出（`whoami`、`id -un` 同样报错）。
运行时是非 root，改不了 `/etc/passwd`，只能修进镜像。

**修复**：镜像里预建 `dev1001` / `dev1002` / `dev1003`（HOME 指向 `/home/coder-profile`）。
现在开发机里 `id` 显示 `uid=1003(dev1003)`，`whoami` 有输出，SSH 全套可用。

用法：

```bash
bash scripts/11-setup-git-ssh.sh                       # 三台都配：生成密钥 + known_hosts + ~/.ssh/config，并打印公钥
APPS="zk" bash scripts/11-setup-git-ssh.sh             # 只配一台
GIT_NAME="张三" GIT_EMAIL="z@example.com" bash scripts/11-setup-git-ssh.sh   # 顺便设提交身份
SSH_PORT=443 bash scripts/11-setup-git-ssh.sh          # 22 端口被封时改走 ssh.github.com:443
```

然后把脚本打印出来的公钥贴到 **GitHub → Settings → SSH and GPG keys → New SSH key**。
每台开发机一把密钥（各自 HOME、各自 `~/.ssh/id_ed25519`），三台都加即可；
想只维护一把，就把某一台的 `~/.ssh/id_ed25519*` 拷到另外两台的 `~/.ssh/` 下。

验证：

```bash
ssh -T git@github.com      # 加公钥之前: Permission denied (publickey) —— 说明 SSH 通，只差授权
                           # 加公钥之后: Hi <你的用户名>! You've successfully authenticated...
git clone git@github.com:<org>/<private-repo>.git
```

实测：

```
id → uid=1003(dev1003)；ssh-keygen OK；~/.ssh 下 id_ed25519(600)/config(600)/known_hosts
ssh -T git@github.com → Permission denied (publickey)     ← 通道正常，只是没把公钥加到 GitHub
git clone https://github.com/octocat/Hello-World.git → OK（HTTPS 通道也正常）
github.com:22 与 ssh.github.com:443 均可达
```

密钥在 `~/.ssh/`（HOME 持久化挂载）：**Pod 重建不丢，`kind delete cluster` 会丢**。

### 9.7 让镜像在本地 kind 与阿里云 ACK 上行为一致

这个镜像的最终目标是跑在阿里云 ACK（节点是 Aliyun Cloud Linux 的 ECS），本地 kind 只是原型。
为保证"同一个镜像，两边行为一样"，做了四件事。

**① 把所有会漂移的东西钉死**（`image/Dockerfile`）

| 项 | 之前 | 现在 |
| --- | --- | --- |
| 基础镜像 | `codercom/code-server:latest` | `codercom/code-server:4.137.0@sha256:57ac68…607971` |
| kubectl | `stable-1.36.txt`（随时间变） | `v1.36.4`（固定） |
| Codex | `0.155.1` | `0.155.1`（固定） |
| 运行时身份 | uid 1001~1003 + `/etc/passwd` + `/etc/subuid` + `storage.conf(vfs)` | 不变 |
| 依赖下载源 | 只有 apt 走阿里云 | 再加 `GOPROXY=goproxy.cn` / `PIP_INDEX_URL=阿里云pypi` / `NPM_CONFIG_REGISTRY=npmmirror`（都是 ENV，部署里可用同名变量覆盖） |

**② 运行契约**（kind 和 ACK 必须一致，否则行为不同）

```
runAsUser/runAsGroup = 1001 / 1002 / 1003    # 每台一个，用于目录隔离；镜像已内置同名用户与 subuid
HOME                 = /home/coder-profile   # 持久化挂载点（代码、扩展、~/.codex、~/.ssh 都在这里）
工作目录              = /workspace            # 各自的数据目录挂到这里
监听端口              = 8080
不依赖宿主 docker/containerd、不依赖节点上的任何路径
```

**③ 镜像自检 + 一致性校验（已跑通）**

镜像内置 `/usr/local/bin/image-selfcheck`，输出分五段：
`[image]`（镜像里烧死的内容，两边必须一致）/ `[platform]` / `[contract]` / `[tools]` / `[mounts]`。

```bash
bash scripts/12-verify-image-parity.sh
```

它会在本地 `docker run` 跑一次、再在集群三个 Pod 里各跑一次，只比对 `[image]` 段。实测：

```
本地镜像 vtf/codeserver-dev:7  Id=sha256:6b9867…f6d13
集群侧 codeserver-lqm / yl / zk  ->  [image] 段对比：完全一致 ✓
结论：本地与集群使用同一份镜像内容 ✓
```

**④ 顺手修掉一个必然踩的"环境相关"坑**

基础镜像的 `WORKDIR` 是 `/home/coder`（属主 uid 1000），而本镜像以 uid 1001~1003 运行，
于是 `kubectl exec` / `docker exec` 进去会落在**不可访问的目录**，任何调用 `getcwd()` 的工具都报错：

```
go: cannot determine current directory: stat .: permission denied
```

这在 kind 和 ACK 上都会发生（也正是自检第一次跑出差异的原因）。已修：
`WORKDIR /workspace` + `chmod 0755 /home/coder`。现在本地和集群里 exec 进去都是
`cwd=/workspace`，`go version` 正常。

**⑤ 推到 ACK 的正确姿势**

```bash
# 1) 只构建一次
bash scripts/09-build-image.sh
# 2) 推到你自己的 ACR（个人版/企业版都行）
docker tag vtf/codeserver-dev:7 registry.cn-<region>.aliyuncs.com/<ns>/codeserver-dev:7
docker push registry.cn-<region>.aliyuncs.com/<ns>/codeserver-dev:7
# 3) kind 和 ACK 都引用同一个 digest，别再各自 build
kubectl -n dev set image deploy/codeserver-lqm \
  code-server=registry.cn-<region>.aliyuncs.com/<ns>/codeserver-dev@sha256:<digest>
```

* 改镜像就换 tag（`:8`），不要覆盖已有 tag
* ACK 节点若是 arm64 实例，用 `docker buildx build --platform linux/amd64,linux/arm64 … --push`
* 换到新环境后重跑 `bash scripts/12-verify-image-parity.sh` 验一次

### 9.8 镜像体积构成（结论：不瘦身）

`vtf/codeserver-dev:7` 解压后 4.34GB，实测构成：

| 部分 | 大小 | 说明 |
| --- | --- | --- |
| 基础镜像 `codercom/code-server:4.137.0` | 1.51GB | 其中 `code-server` 包自己 689MB（VS Code Web 全部前端资源 + 捆绑 Node），砍不动 |
| apt 工具链（本仓库加的） | 1.48GB | Go 工具链 ~250MB、podman/buildah 一组 ~310MB、gcc/g++/cmake ~220MB、Node+Python ~150MB、git+依赖 ~200MB… |
| Codex CLI | 517MB | `@openai/codex-linux-x64` 平台包 354MB，换官方 tarball 也一样大 |
| kubectl v1.36.4 | 60MB | |

曾经评估过的瘦身项与结论：

| 项 | 省 | 结论 |
| --- | --- | --- |
| `golang-1.24-src`（Go 标准库源码） | 132MB | ❌ **必需**。Go 1.20+ 不再预编译标准库（`pkg` 下 `.a` 文件数为 0），`fmt` 等包都从 src 按需编译。实测删掉后 `go build/run/vet/test/doc` 全部失败（`package fmt is not in std`） |
| podman/buildah/skopeo/uidmap 一组 | ~310MB | ⚠️ 可砍但**保留**：留着就能在开发机里 `podman build` 调试 Dockerfile |
| `/usr/share/doc` + `/usr/share/man` | 74MB | ⚠️ 可砍但保留 |
| locale 精简（只留 zh/en） | ~75MB | ⚠️ 可砍但保留（保留多语言报错信息） |
| Codex 改原生二进制 | 0 | 无收益（同一个平台包） |
| gcc/g++/cmake/python3-dev/node | ~350MB | ❌ 编 C 扩展、cgo、node-gyp、pip 源码包全靠它们 |

**决定：全部保留**，不为此增加构建复杂度。推送/拉取传的是压缩层（本机镜像元数据里压缩后约 1.1GB 量级），
ACK 从 ACR 内网拉取也快，体积不是瓶颈。

### 9.9 在开发机容器里构建镜像（BuildKit 方案，已实测）

**问题**：开发机 Pod 是非特权的（uid 1001~1003，为了隔离），在里面直接跑 podman/buildah 会失败：

```
newuidmap: write to uid_map failed: Operation not permitted   ← 多段 uid 映射要 CAP_SETUID
  └─ 退回单映射后解压镜像失败: requested 0:42 for /etc/shadow
vfs 驱动不支持 ignore_chown_errors / 没有 /dev/fuse / userns 里挂 overlay 不支持
```

给 Pod 加 `privileged: true` 能绕过（实测 podman 构建 10 秒 + 推送成功），但**会破坏三台之间的隔离**。

**推荐方案：构建交给独立的 BuildKit 服务，code-server 里只放客户端**

镜像 `:8` 起**已内置** `buildctl`（客户端）+ `devbuild`（便捷封装），开发机里开箱可用。

```bash
# 1) 部署 buildkitd（清单已备好；ACK 上把 hostPath 换成 PVC）
kubectl apply -f manifests/30-buildkitd.yaml

# 2) 私有仓库先登录（ACR / Harbor / 内网 registry 都适用）
#    buildctl 会读取 ~/.docker/config.json 里的凭据去推镜像，用 podman 写这个文件即可
podman login --authfile ~/.docker/config.json -u <用户名> <registry>

# 3) 一条命令构建 + 推送（在开发机终端里，不需要特权、不需要 docker daemon）
cd /workspace/myapp
devbuild -t registry.cn-hangzhou.aliyuncs.com/<ns>/<repo>:<tag> .
devbuild -t registry.dev.svc.cluster.local:5000/myapp:1 --insecure .      # 集群内 HTTP registry
devbuild --help                                                          # 其它参数（-f / BUILDKIT_HOST）
```

**实测结果**（kind 里，从非特权的 code-server 容器发起）：

```
buildctl github.com/moby/buildkit v0.33.0
#6 pushing manifest for .../demo-buildkit:1 done
构建+推送耗时: 7s
仓库内容: {"repositories":["demo","demo-buildkit"]}

# 用内置的 devbuild 再跑一次（缓存命中，2 秒）
devbuild -t registry.dev.svc.cluster.local:5000/devbuild-demo:1 --insecure /tmp/db
仓库内容: {"repositories":["demo","demo-buildkit","devbuild-demo"]}
```

**为什么比"给 Pod 特权"好**

* code-server 容器保持非特权，三台之间的目录隔离不变
* BuildKit 不开放 `--allow-insecure-entitlement security.insecure`，构建步骤跑在它自己的沙箱里，
  用户无法用 Dockerfile 触达节点文件系统（比给 Pod 挂 docker.sock 安全得多）
* 缓存放持久化目录，多次构建很快；`--addr` 只开 ClusterIP + NetworkPolicy，外界访问不到

**ACK 落地要点**

| 项 | 做法 |
| --- | --- |
| 缓存 | `hostPath` → PVC（`alicloud-disk-essd` 或 NAS 都行） |
| 网络 | ClusterIP + NetworkPolicy 只放行开发机 Pod（清单里已写） |
| 权限 | buildkitd 需要 `privileged: true`；确认节点池/安全策略允许，或改 rootless 模式（`--oci-worker-no-process-sandbox`）另行验证 |
| 隔离度 | 三台共用一个 buildkitd（简单、缓存共享）；要各自独立就一个用户一个 buildkitd + 独立 PVC |
| 客户端 | 已内置 `buildctl` + `devbuild`（`:8` 起，约 40MB） |

和 ACR 构建不冲突：**BuildKit 适合"在开发机里随手造镜像调试"，ACR/云效适合正式流水线**。

## 10. 已知限制

* 只提供 **HTTP**（443 被 VMware 占用），没有 TLS。
* 密码是三台**各自独立**的，但都比较简单（`CHANGE_ME_lqm`/`CHANGE_ME_yl`/`CHANGE_ME_zk`）且以明文写在
  `manifests/05-codeserver-passwords.yaml`（方便本地开发）。改成强密码：
  ```bash
  kubectl -n dev create secret generic codeserver-passwords \
    --from-literal=lqm="$(openssl rand -base64 12)" \
    --from-literal=yl="$(openssl rand -base64 12)" \
    --from-literal=zk="$(openssl rand -base64 12)" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n dev rollout restart deploy
  ```
  想彻底关登录：把三处 `--auth password` 改成 `--auth none` 并删掉 `PASSWORD` 环境变量 ——
  ⚠️ 那样局域网里任何人打开链接就能拿到你代码目录的 shell，不建议。
* 集群与所有 Pod 都跑在 Docker Desktop 里，**Docker Desktop 停掉集群就不可用**。
  而且 kind 节点容器是 `--restart=on-failure:1`，**Docker Desktop / Windows 重启后不会自动拉起**，
  跑一下 `bash scripts/07-start-cluster.sh` 即可恢复（不用重建，数据也在）。
  想开机自动恢复，就把这个脚本加到 WSL 的启动项里。
* 数据持久化见第 6 节；方案 A 下删集群等于删数据。


---

## ⚠️ 公开版说明（占位符）

本仓库是**脱敏公开版**，以下内容已被替换成占位符，使用时请替换为你自己的值：

| 占位符 | 说明 |
| --- | --- |
| `codeserver.example.com` | 你的访问域名 |
| `<your-dockerhub-user>` | 你的 Docker Hub 用户名（镜像地址里） |
| `<your-acr-username@your-account-id>`、`0000000000000000` | ACR / 阿里云 RAM 账号信息 |
| `your-acr-registry(.cn-hangzhou.cr.aliyuncs.com)` | ACR 实例地址 |
| `alb-xxxxxxxxxxxxxxxx`、`<node-ip>` | ALB / 节点标识 |
| `CHANGE_ME_lqm` / `CHANGE_ME_yl` / `CHANGE_ME_zk` | 三台开发机的登录密码 |
| `/home/<user>`、`<user>` | 本机用户名相关路径 |

集群名、节点池标签（`worker.role=tools`）、命名空间（`vtf-tools`）等**业务命名保留原样**。
