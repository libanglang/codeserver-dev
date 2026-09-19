# ACK 版部署说明（命名空间 vtf-tools / 节点池 role=tools）

对应你的环境：**污点 `role=tools`、标签 `worker.role=tools`、命名空间 `vtf-tools`**。

## 与本地 kind 版的四个差异（都是 ACK 特有的坑）

| 项 | kind 版 | ACK 版 | 为什么 |
| --- | --- | --- | --- |
| 节点选择 | `nodeSelector: vtf.io/worker=worker02` | `nodeSelector: worker.role=tools` **+ 容忍污点 `role=tools`** | 你的 tools 节点池有污点，不容忍就永远 Pending |
| 存储 | `hostPath` | **每台一块独立 ESSD 云盘**（`pvc-code-server-{lqm,yl,zk}`，RWO/20Gi/`alicloud-disk-essd-hangzhou-k`） | 一人一块盘，跨用户访问在存储层就不可能；云盘是 RWO，一台只挂自己那块，不冲突 |
| 隔离 | 节点目录 0700 + 不同 uid | 每台盘内目录 0700 + 不同 uid（initContainer 以 root 建 `.profile` 并 chown） | 逻辑不变，换到云盘；详见下方"单块盘的布局" |
| 访问方式 | 路径 `/dev/group/vtf/lqm/` | **同样用路径** + **Pod 内 nginx sidecar 剥前缀** | ALB 没有 nginx 那套 `rewrite-target` 注解；把"剥前缀 + 补斜杠"放进 sidecar，ALB 只做最朴素的路径转发 |
| 组件 | 1 个容器/Pod | **2 个容器/Pod**（`proxy` + `code-server`） | sidecar 只为剥前缀，资源占用很小（20m CPU / 32Mi 起） |

## 部署前需要改的 3 个值

1. `10-codeserver-apps.yaml` 的镜像（三选一，见下）
2. `20-ingress.yaml` 的域名（我按 `*.codeserver.example.com` 写的，改域名记得 DNS 也要指到 ALB/SLB）
3. （可选）`05-storage.yaml` 的容量 / StorageClass —— 已按你给的值写好：
   `alicloud-disk-essd-hangzhou-k` / RWO / 20Gi / Filesystem

## 单块盘的布局（云盘 RWO 的连带影响）

云盘同一时刻只能挂到一个节点，所以**每台的工作目录和 profile 必须在同一块盘里**：

```
pvc-code-server-lqm（20Gi ESSD）
├── /                → 挂到容器 /workspace               （你的代码）
└── .profile/        → 挂到容器 /home/coder-profile       （扩展、设置、~/.codex、~/.ssh）
```

`.profile` 由 Deployment 的 initContainer（root）创建并 chown 到该台的 uid（1001/1002/1003），主容器里看不到别的内容。

⚠️ 云盘的另外两个特性：

* **可用区绑定**：SC 是 `…-hangzhou-k`，PV 创建在 hangzhou-k，CSI 会给 PV 加 nodeAffinity —— Pod 只会被调度到该可用区的节点（tools 池若跨可用区，实际只落在 hangzhou-k 的节点上）。
* **换节点要重新挂盘**：节点故障/驱逐后 Pod 漂到别的节点时，会有约 30~60 秒的 `ContainerCreating` 等盘挂载，属正常。

## 镜像从哪来（重要）

你的 ACK 节点**连不上 Docker Hub**（实测 `curl https://registry-1.docker.io/v2/` 返回 000、pull 超时）。所以：

| 方案 | 写法 | 前提 |
| --- | --- | --- |
| **ACR（推荐）** | `your-acr-registry-vpc.cn-hangzhou.cr.aliyuncs.com/vtf/tools/codeserver-dev:v1` | 等 RAM 权限批下来后推上去；ACK 从 VPC 内网拉，快且无限流 |
| 节点已离线导入 | `docker.io/<your-dockerhub-user>/codeserver-dev:8` + `imagePullPolicy: IfNotPresent` | 先用 `ctr -n k8s.io images import` 把 tar 导入到**每个** tools 节点 |
| 配了镜像加速器 | `docker.io/<your-dockerhub-user>/codeserver-dev:8` | 节点上配好 containerd registry mirror |

> 离线导入的做法：本地 `docker save <your-dockerhub-user>/codeserver-dev:8 | gzip -1 > cs8.tar.gz`（约 1.1GB）
> → 传到 OSS → 节点用内网端点下载 → `ctr -n k8s.io images import cs8.tar.gz`。
> 三个 tools 节点都要导入（镜像缓存是按节点的）。

## 部署顺序

```bash
kubectl apply -f manifests/ack/00-namespace.yaml
kubectl apply -f manifests/ack/05-storage.yaml        # 3 块 ESSD（已按你给的 SC 写好）
kubectl apply -f manifests/ack/12-proxy-config.yaml   # nginx sidecar 配置（剥前缀/补斜杠）
kubectl apply -f manifests/ack/15-passwords.yaml      # 三台密码
kubectl apply -f manifests/ack/10-codeserver-apps.yaml
kubectl apply -f manifests/ack/20-ingress.yaml        # ALB Ingress（域名 codeserver.example.com）

kubectl -n vtf-tools get pods -o wide               # 三个 Pod 都应 Running 且落在 tools 节点
kubectl -n vtf-tools get pvc
kubectl -n vtf-tools get ingress                    # 拿到 ALB/SLB 地址后配 DNS
```

## 验收

```bash
# 在集群里直接验证（不依赖 DNS/Ingress）
kubectl -n vtf-tools run curl --rm -it --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w '%{http_code}\n' http://codeserver-lqm:8080/      # 期望 302

# 验证三台隔离：每台只能看到自己的 /workspace
for a in lqm yl zk; do
  echo "--- $a"; kubectl -n vtf-tools exec deploy/codeserver-$a -- sh -c 'id; ls -la /workspace; ls /data 2>&1 | head -1'
done
```

浏览器访问（把 `codeserver.example.com` 解析指到 ALB 的 DNS 名称后）：

```
http://codeserver.example.com/dev/group/vtf/lqm/   (密码 CHANGE_ME_lqm)
http://codeserver.example.com/dev/group/vtf/yl/    (密码 CHANGE_ME_yl)
http://codeserver.example.com/dev/group/vtf/zk/    (密码 CHANGE_ME_zk)
```

两个细节：

* **地址要带结尾的 `/`**（code-server 的静态资源和 WebSocket 用相对路径）。不带斜杠也能用 —— 清单里的三个 `codeserver-redirect-*` Ingress 会 301 跳过去。
* **域名**：本清单按你给的 `codeserver.example.com` 写；本地 kind 环境当前用的是 `codeserver.example.com`，两边不一致的话全局替换即可（或告诉我改成哪个）。
* **公网域名在国内需要备案**；只在内网用的话，把 Nginx Ingress 的 Service 用内网 SLB，DNS 指内网地址。

## 可选组件

* **在集群里构建镜像**：`kubectl apply -f manifests/ack/30-buildkitd.yaml`，它会建一块 100Gi 的 ESSD 作为构建缓存，并起一个 buildkitd（同样在 tools 节点池、容忍相同污点）。
  * 开发机的 `BUILDKIT_HOST` 已在 Deployment 里设为 `tcp://buildkitd.vtf-tools.svc.cluster.local:1234`
  * 用之前先在开发机里登录目标仓库（凭据随各自的 PVC 持久化）：
    `podman login --authfile ~/.docker/config.json -u <用户名> your-acr-registry-vpc.cn-hangzhou.cr.aliyuncs.com`
  * 然后：`devbuild -t your-acr-registry-vpc.cn-hangzhou.cr.aliyuncs.com/<ns>/<repo>:<tag> .`
  * ⚠️ buildkitd 的镜像来自 Docker Hub（`moby/buildkit`），而 ACK 节点连不上 —— 需先推到 ACR 或离线导入（同 code-server 镜像的处理方式，见上文"镜像从哪来"）
  * ⚠️ buildkitd 需要 `privileged: true`；ACK 默认允许，若被安全策略拦截，需换节点池或改 rootless 模式
* **Codex 密钥**：改 `scripts/10-setup-codex.sh` 里的 `NAMESPACE`/`APPS` 后对 ACK 执行（或进 Pod 手工配）
* **GitHub SSH**：同理用 `scripts/11-setup-git-ssh.sh`

---

## 实测记录（2026-09-19，真实 ACK 集群 v1.36.2-aliyun.1）

按上面的顺序部署后逐项验证，全部通过：

```
Pod        3 台 2/2 Running，全部调度到 tools 节点（cn-hangzhou.<node-ip>）✓
PVC        pvc-code-server-{lqm,yl,zk} 全部 Bound（ESSD, hangzhou-k）            ✓
Endpoints  三个 Service 都注册到 sidecar 端口 8888                              ✓
Ingress    ALB 地址正常下发，健康检查通过                                        ✓
端到端      经 ALB 访问三条路径：
             /dev/group/vtf/lqm/ -> 302，cookie=code-server-session--lqm  页面 200(4389B) 静态资源 200
             /dev/group/vtf/yl/  -> 302，cookie=code-server-session--yl   页面 200(4389B) 静态资源 200
             /dev/group/vtf/zk/  -> 302，cookie=code-server-session--zk   页面 200(4389B) 静态资源 200
             （cookie 名带各自后缀 => 证明三条路径分别路由到了正确的 Pod）
             /dev/group/vtf/lqm（不带斜杠）-> 301 Location: /dev/group/vtf/lqm/（相对路径）✓
```

### 部署时踩到并已在清单里修掉的 5 个坑

| # | 现象 | 根因 | 修法（已写进清单） |
| --- | --- | --- | --- |
| 1 | sidecar 容器 `CrashLoopBackOff`：`mkdir() "/var/cache/nginx/client_temp" failed` | **Pod 级 `runAsUser: 1001`**（本来是给 code-server 做隔离的）也套到了 nginx 上，而 nginx 官方镜像需要 root 建缓存目录 | 给 `proxy` 容器单独加容器级 `securityContext: {runAsUser: 0}`（容器级覆盖 Pod 级；该容器只挂只读 ConfigMap，不影响隔离） |
| 2 | 301 跳转地址变成 `http://<host>:8888/dev/...`（暴露内部端口，用户点跳转会失败） | nginx 默认 `absolute_redirect on` 会把相对地址补成绝对地址并带上自己的端口 | sidecar 配置加 `absolute_redirect off; port_in_redirect off;` |
| 3 | ALB 探活失败 → 访问返回 **503**（不是 502/404） | ALB 的默认健康检查路径是 `/`，而 sidecar 的 `/` 返回 404 → 后端被判不健康 | nginx 里加 `location = / { return 200 "ok"; }`；并把 `healthcheck-path` 指到 `/readyz`（转发到 code-server 真实健康端点） |
| 4 | 其中一个 Service 有 selector 却**没有 Endpoints** | 复用了**已存在**的 Service（旧 selector 里有 `app: code-server-lqm`），`kubectl apply` 对 map 是**合并**，旧键被保留 → 匹配不到新 Pod | 删掉 Service 重新 apply（全新部署不会遇到）；排查命令：`kubectl -n vtf-tools get endpoints` |
| 5 | 访问自己的域名返回 **403**，`Server: Beaver`、标题 `Non-compliance ICP Filing` | 公网 ALB 的 80 端口做 **ICP 备案校验**，域名未备案被阿里云边缘拦截（与集群配置无关） | 三选一：①域名做 ICP 备案；②用内网 ALB（`address-type: intranet`）；③临时用 ALB 自带域名（已备案），见 `20-ingress.yaml` 末尾的说明 |

### 另外两个环境相关的注意点

* **镜像全部要走镜像站**：ACK 节点连不通 Docker Hub（实测 `i/o timeout`），所以三个镜像都要用镜像站地址 ——
  `docker.1ms.run/<your-dockerhub-user>/codeserver-dev:8`（code-server）、`docker.1ms.run/library/nginx:1.27-alpine`（sidecar）、
  `docker.1ms.run/library/busybox:1.36`（initContainer）。长期建议推到 ACR 用内网地址。
* **`kubectl exec` / `kubectl debug` 在本次网络下不稳定**（apiserver→kubelet:10250 偶发超时）。
  节点上执行命令的替代：ECS 云助手 / SSH；或者 `kubectl debug node/<node>` 多试几次。

### 一次 apply 的合并清单

为方便部署，6 个文件也合并成了一份（内容完全一致，同样对真实集群 dry-run 通过）：

```bash
kubectl apply -f manifests/ack/codeserver-ack-all.yaml     # 13 个对象
# 可选：集群内构建镜像
kubectl apply -f manifests/ack/30-buildkitd.yaml
```

### BuildKit 组件的实测记录（2026-09-19，同样在真实 ACK 上跑通）

`30-buildkitd.yaml` 也部署到 ACK 验证过：

```
buildkitd       1/1 Running（本集群允许 privileged），100Gi ESSD 缓存盘 Bound
buildctl        v0.33.0，worker 就绪（linux/amd64 等平台）
第一次构建+推送  13s（推送到临时 registry）
第二次构建       命中缓存，0s
普通 Dockerfile  用不带前缀的 `FROM alpine:3.20` 构建 → 3s 成功并推送
                （证明 ConfigMap 里的 docker.io mirror 配置生效）
临时 registry    tags = ["1","2"]、mirror-test:["1"] —— 构建和推送都真的成功
```

为了让普通 Dockerfile 能直接用，`30-buildkitd.yaml` 里加了一个 ConfigMap：

```toml
[registry."docker.io"]
  mirrors = ["docker.1ms.run"]
```

**不加这个配置** buildkitd 拉不动 Docker Hub 的基础镜像（ACK 节点连不通 docker.io），
只能把 Dockerfile 写成 `FROM docker.1ms.run/library/alpine:3.20`。

验证用的临时 registry 和所有 buildkit 资源在验证后都已删除，仓库里保留的是确认版清单。
