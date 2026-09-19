# 所有脚本共用的变量（被 source，不要直接执行）
# 想改集群名/版本/域名，改这里或临时用环境变量覆盖，例如：
#   CLUSTER_NAME=demo bash scripts/01-create-cluster.sh

export CLUSTER_NAME="${CLUSTER_NAME:-vtf-dev}"
export K8S_VERSION="${K8S_VERSION:-v1.36.4}"
export KIND_IMAGE="${KIND_IMAGE:-kindest/node:${K8S_VERSION}}"
export NAMESPACE="${NAMESPACE:-dev}"
export INGRESS_HOST="${INGRESS_HOST:-codeserver.example.com}"
export WORKER01="${CLUSTER_NAME}-worker"    # kind 里的第一个 worker
export WORKER02="${CLUSTER_NAME}-worker2"   # kind 里的第二个 worker = worker02
export BASE_DATA_DIR="${BASE_DATA_DIR:-/data/group/vtf}"
# 三台开发机：名称:uid。uid 必须与 manifests/10-codeserver-apps.yaml 里的 runAsUser 一致，
# 靠"不同 uid + 目录 0700"实现三者之间的文件系统隔离（只用 POSIX 权限，无额外组件）。
export CODESERVER_APPS="${CODESERVER_APPS:-lqm:1001 yl:1002 zk:1003}"
export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIND_CONFIG="${KIND_CONFIG:-${REPO_ROOT}/kind/kind-cluster.yaml}"
export KUBECONFIG_OUT="${KUBECONFIG_OUT:-${REPO_ROOT}/kind-${CLUSTER_NAME}.yaml}"

# 统一日志前缀
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "找不到命令 $1，请先执行 bash scripts/00-install-tools.sh"
}
