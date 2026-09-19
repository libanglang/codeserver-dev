# ============================================================================
# 开发机镜像：code-server + 常用工具链
#
# 为什么必须自建：
#   官方 codercom/code-server 镜像只带 git/curl/wget/tar（实测 gcc/make/python3/
#   node/npm/go/java 全都没有），而容器以非 root（uid 1001~1003）运行、/usr 不可写，
#   运行时装不了系统级依赖。工具链必须在构建阶段装进镜像。
#
# 构建 + 载入 kind + 切换三台开发机：
#   bash scripts/09-build-image.sh
#   WITH_JAVA=1 WITH_GO=1 WITH_RUST=1 bash scripts/09-build-image.sh
#
# 手动等价操作：
#   docker build -t vtf/codeserver-dev:1 image
#   kind load docker-image vtf/codeserver-dev:1 --name vtf-dev
#   kubectl -n dev set image deploy/codeserver-lqm code-server=vtf/codeserver-dev:1
#
# 版本参考（Debian 13 trixie 实测可用）：python 3.13 / node 20.19 / npm 9.2 /
#   openjdk 21 / maven 3.9 / go 1.24 / rustc+cargo 1.85 / cmake 3.31
#
# 默认包含：Python 3.13 + pip/venv、Node 20 + npm、Go 1.24、gcc/g++/make/cmake、Codex CLI
# 可选：WITH_JAVA=1、WITH_RUST=1
# ============================================================================
# 基础镜像钉死到 tag+digest：避免 "latest" 漂移导致本地/ACK 构建出不同内容
FROM codercom/code-server:4.137.0@sha256:57ac684d44deb6fa94317b3e8f3e128dd7fb897fffd95b4efcd16f56ce607971

LABEL org.opencontainers.image.title="codeserver-dev" \
      org.opencontainers.image.description="code-server dev box: go/python/node/gcc/cmake + codex + podman, for kind & Aliyun ACK" \
      org.opencontainers.image.base.name="codercom/code-server:4.137.0" \
      org.opencontainers.image.base.digest="sha256:57ac684d44deb6fa94317b3e8f3e128dd7fb897fffd95b4efcd16f56ce607971"

USER root
ARG DEBIAN_FRONTEND=noninteractive
ARG WITH_JAVA=0
ARG WITH_GO=1
ARG WITH_RUST=0
ARG WITH_KUBECTL=1
# 国内网络下 deb.debian.org 只有几百 KB/s 且经常超时（实测 162MB 下了 6 分 41 秒还没完），
# 所以默认换成阿里云镜像；要用官方源：--build-arg APT_MIRROR=http://deb.debian.org
ARG APT_MIRROR=https://mirrors.aliyun.com

RUN set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
      sed -i "s|http://deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    pkgs="build-essential pkg-config cmake make g++ \
          python3 python3-pip python3-venv python3-dev \
          nodejs npm \
          podman buildah uidmap skopeo \
          git curl wget unzip zip jq ca-certificates gnupg \
          ripgrep fd-find less vim-tiny procps iproute2 netcat-openbsd \
          sqlite3 libssl-dev zlib1g-dev"; \
    if [ "$WITH_JAVA" = "1" ]; then pkgs="$pkgs openjdk-21-jdk-headless maven"; fi; \
    if [ "$WITH_GO" = "1" ]; then pkgs="$pkgs golang-go"; fi; \
    if [ "$WITH_RUST" = "1" ]; then pkgs="$pkgs rustc cargo"; fi; \
    apt-get update; \
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends $pkgs; \
    rm -rf /var/lib/apt/lists/*; \
    # Debian 13 有 PEP668 标记，会拦住 `pip install --user`；开发机上去掉它，
    # 同时建议优先用 venv（见 README）。
    rm -f /usr/lib/python3*/EXTERNALLY-MANAGED

# fd 在 Debian 里叫 fdfind，补一个常用名
RUN ln -sf "$(command -v fdfind)" /usr/local/bin/fd

# 把自检脚本烧进镜像：本地 kind 和 ACK 里跑的是同一份，输出可直接 diff
COPY selfcheck.sh /usr/local/bin/image-selfcheck
RUN chmod +x /usr/local/bin/image-selfcheck

# ------------------------------------------------------------------ 工作目录 --
# 基础镜像的 WORKDIR 是 /home/coder，属主 coder(1000)。但本镜像运行时会以
# uid 1001~1003 启动（目录隔离需要），这些 uid 连 stat /home/coder 都会 Permission denied，
# 于是 kubectl exec / docker exec 进去后落在"不可访问的目录"，任何调用 getcwd 的工具
# （go、部分 node 工具、crun 起容器）都会直接报错：
#     go: cannot determine current directory: stat .: permission denied
# 修法：① 放开 /home/coder 的可遍历权限；② 把默认工作目录改成 /workspace，
# 让 exec 进去就在开发目录里（和浏览器终端一致）。kind 与 ACK 行为因此一致。
RUN chmod 0755 /home/coder; \
    mkdir -p /workspace; \
    chmod 0755 /workspace
WORKDIR /workspace

# ------------------------------------------------- rootless 镜像构建(storage) --
# 开发机 Pod 里没有 Docker daemon，也不给特权（否则会破坏三台之间的隔离），
# 所以用 rootless 的 podman/buildah 在容器内直接构建镜像。
# 存储驱动只能选 vfs：
#   - 没有 /dev/fuse  => fuse-overlayfs 不可用
#   - 底层文件系统本身就是 overlayfs，userns 里挂 overlay 会报
#     "filesystem on ... not supported as upperdir"
# vfs 不依赖任何额外内核能力，代价是每层完整拷贝（吃磁盘、比 overlay 慢），
# 对"偶尔构建 + 推送"完全够用。镜像/层都存在 $HOME/.local/share/containers（持久化）。
RUN printf '[storage]\ndriver = "vfs"\n' > /etc/containers/storage.conf; \
    podman --version; buildah --version | head -1

# ------------------------------------------------------------------ Codex CLI -
# 装到 /usr/local（系统级），不要装进 $HOME：运行时会话里 HOME 被持久化目录覆盖，
# 装在 $HOME 里的东西会被"盖掉"看不见。
# 国内 npm 慢可以加：--build-arg NPM_REGISTRY=https://registry.npmmirror.com
ARG CODEX_VERSION=0.155.1
ARG NPM_REGISTRY=
# kubectl 版本也钉死（之前用 stable-1.36.txt，会随时间漂移）
ARG KUBECTL_VERSION=v1.36.4
# BuildKit 客户端版本（服务端在 manifests/30-buildkitd.yaml，版本要匹配）
ARG BUILDKIT_VERSION=v0.33.0
RUN set -eux; \
    if [ -n "$NPM_REGISTRY" ]; then reg="--registry=$NPM_REGISTRY"; else reg=""; fi; \
    npm install -g --prefix /usr/local $reg "@openai/codex@${CODEX_VERSION}"; \
    /usr/local/bin/codex --version

# --------------------------------------------------- BuildKit 客户端(buildctl) -
# 开发机 Pod 非特权，容器内不能自己跑容器构建（实测 userns/uid_map 受限）。
# 标准做法：构建交给独立的 buildkitd 服务，容器里只放客户端 + 一个便捷脚本 devbuild。
# 只装 buildctl（客户端），不装 buildkitd（它是服务端，跑在单独的 Pod 里）。
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    tmp="$(mktemp -d)"; \
    curl -4 -fsSL "https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-${arch}.tar.gz" \
      | tar -xz -C "$tmp" bin/buildctl; \
    install -m 0755 "$tmp/bin/buildctl" /usr/local/bin/buildctl; \
    rm -rf "$tmp"; \
    buildctl --version
COPY devbuild.sh /usr/local/bin/devbuild
RUN chmod +x /usr/local/bin/devbuild

# 集群内 BuildKit 服务的默认地址（可用同名环境变量覆盖）
ENV BUILDKIT_HOST=tcp://buildkitd.dev.svc.cluster.local:1234

# 可选：容器内也能用 kubectl（镜像里用不到集群权限时没必要，默认关）
RUN if [ "$WITH_KUBECTL" = "1" ]; then \
      arch="$(dpkg --print-architecture)"; \
      curl -4 -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"; \
      chmod +x /usr/local/bin/kubectl; \
    fi

# --------------------------------------------------------- 运行时身份(uid) ------
# 三台开发机分别以 uid 1001/1002/1003 运行（不同 uid 是实现目录隔离的基础），
# 但基础镜像里只有 coder(1000)。OpenSSH 的 ssh / ssh-keygen 需要通过 getpwuid 查到当前 uid，
# 查不到会直接失败：
#     $ ssh-keygen -t ed25519 ...
#     No user exists for uid 1003
# 结果不只是生成不了密钥，git 走 SSH 也一起废掉。这里预建这几个 uid 的用户解决。
# HOME 指向运行时会挂载的 /home/coder-profile，保证 ssh/git 找到的 home 与真实 HOME 一致。
ARG DEV_UIDS="1001 1002 1003"
RUN set -eux; \
    for u in $DEV_UIDS; do \
      getent group "$u" >/dev/null 2>&1 || groupadd -g "$u" "dev$u"; \
      getent passwd "$u" >/dev/null 2>&1 || useradd -u "$u" -g "$u" -d /home/coder-profile -s /bin/bash -M "dev$u"; \
    done; \
    getent passwd 1001 1002 1003

# ------------------------------------------------------------------ 运行环境 --
# 这些 ENV 决定"开发机里装依赖走哪个源"。写进镜像是为了让本地 kind 和 ACK 行为一致
# （两边都在国内网络；这些镜像站公网可达）。要覆盖就在 Deployment 的 env 里设同名变量。
ENV GOPROXY=https://goproxy.cn,direct \
    PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ \
    NPM_CONFIG_REGISTRY=https://registry.npmmirror.com

USER coder

# 用户级安装 / 各种包缓存全部落到 $HOME。
# 运行时会话里 HOME=/home/coder-profile，它是 hostPath 挂载 => 重启不丢。
ENV npm_config_prefix=/home/coder-profile/.npm-global \
    GOPATH=/home/coder-profile/go \
    GOMODCACHE=/home/coder-profile/go/pkg/mod \
    CARGO_HOME=/home/coder-profile/.cargo \
    PIP_CACHE_DIR=/home/coder-profile/.cache/pip \
    PATH=/home/coder-profile/.npm-global/bin:/home/coder-profile/.local/bin:/home/coder-profile/go/bin:/home/coder-profile/.cargo/bin:/usr/local/go/bin:$PATH
