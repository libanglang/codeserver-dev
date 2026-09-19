#!/usr/bin/env bash
# 在 worker02 节点上准备 hostPath 目录，并把属主改成 1000（容器内 coder 用户）
# 必须在创建 Pod 之前执行，否则 hostPath type=Directory 会挂载失败
set -euo pipefail
source "$(dirname "$0")/env.sh"
require_cmd docker

log "准备 $WORKER02 上的目录（名称:uid —— ${CODESERVER_APPS}）"

for item in $CODESERVER_APPS; do
  name="${item%%:*}"
  uid="${item##*:}"
  log "  ${BASE_DATA_DIR}/${name}  属主 ${uid}:${uid}  权限 0700"
  docker exec "$WORKER02" bash -lc "
    set -e
    mkdir -p ${BASE_DATA_DIR}/${name}
    mkdir -p ${BASE_DATA_DIR}/.codeserver/${name}
    # 关键：属主必须是该实例自己的 uid，配合 0700 才能挡住另外两台
    chown -R ${uid}:${uid} ${BASE_DATA_DIR}/${name} ${BASE_DATA_DIR}/.codeserver/${name}
    chmod 700 ${BASE_DATA_DIR}/${name} ${BASE_DATA_DIR}/.codeserver/${name}
  "
done

# 父目录保持 root 所有、0711：可以穿越到自己那层，但不能列出/进入别人的目录
docker exec "$WORKER02" bash -lc "
  set -e
  chown root:root ${BASE_DATA_DIR}
  chmod 711 ${BASE_DATA_DIR}
  chmod 711 ${BASE_DATA_DIR}/.codeserver 2>/dev/null || true
"

log "节点上的目录（注意每行属主不同）："
docker exec "$WORKER02" bash -lc "
  ls -lnd ${BASE_DATA_DIR} ${BASE_DATA_DIR}/* ${BASE_DATA_DIR}/.codeserver/* 2>/dev/null
"

if [[ "$KIND_CONFIG" == *"hostdata"* ]]; then
  log "方案 B：这些目录同时映射在 WSL 的宿主机目录上（见 kind/kind-cluster-hostdata.yaml）"
fi
