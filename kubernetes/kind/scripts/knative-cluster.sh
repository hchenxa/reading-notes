#!/usr/bin/env bash
# knative-cluster.sh — 在两套 kind 环境之间切换：start / stop / status
#
# 这台机器上同时留着两套 kind 集群，区别只在 Knative 的网络层与数据面：
#   knative        —— Knative Serving + net-kourier
#   knative-istio  —— Knative Serving + net-gateway-api + Istio ambient
# 笔记本上没必要让两套同时占内存，用这个脚本把暂时不用的那套停掉。
#
# 关于 "stop"：kind 没有原生的 stop —— 集群本体就是 Docker 容器，所以这里停的是
# 节点容器。关键是**先把 restart policy 改成 no**：kind 节点在 docker stop 超时后
# 会收到 SIGKILL（退出码 137），而它默认是 on-failure 策略，不改的话会被判定为失败
# 并自动拉回来，等于没停。容器的文件系统是持久的 —— 镜像、containerd 配置（含
# registry mirror）、已安装的组件都不会丢，start 回来即可。
#
# 用法：
#   knative-cluster.sh status                    # 两套环境各自的状态
#   knative-cluster.sh start  knative-istio      # 启动并切过去，等组件真正就绪
#   knative-cluster.sh stop   knative-istio      # 停掉并置为不再自动重启
#
# 环境变量：
#   KIND_DOCKER_HOST   Docker endpoint。默认用 colima 的 socket —— 这台机器的
#                      shell profile 把 DOCKER_HOST 固定指向了 podman，而 kind 只认
#                      DOCKER_HOST，所以脚本自己设，不依赖外部环境。
#   KIND_STOP_TIMEOUT  传给 docker stop 的秒数（默认 60）
#   KIND_READY_TIMEOUT 等节点 Ready 的上限秒数（默认 180）
#   KIND_PODS_TIMEOUT  等 knative-serving 组件全部就绪的上限（默认 240）
#
# 编辑本文件的雷区：它在 macOS 自带的 bash 3.2 下运行，变量插值若**紧跟全角字符**
# （比如变量后面直接跟一个全角左括号、全角逗号），bash 3.2 会把那个多字节字符的首
# 字节吞进变量名，报 `unbound variable`。凡是这类位置一律加花括号，写成 ${n}（ 这样。

set -euo pipefail

export DOCKER_HOST="${KIND_DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"
STOP_TIMEOUT="${KIND_STOP_TIMEOUT:-60}"
READY_TIMEOUT="${KIND_READY_TIMEOUT:-180}"
PODS_TIMEOUT="${KIND_PODS_TIMEOUT:-240}"

die()  { echo "错误：$*" >&2; exit 1; }
note() { echo "  $*"; }

# 所有"探测"类命令一律吞掉失败。它们失败的含义是"还没起来 / 连不上"，不是脚本出错，
# 而 set -e + pipefail 会把 `x="$(kubectl ... | tr ...)"` 这种赋值直接判死、脚本静默
# 退出（实测 start 会 3 秒就返回）。所以探测全部走 probe，并且结果都去掉空白。
probe() { "$@" 2>/dev/null || true; }
squash() { tr -d '[:space:]'; }

inspect_f() {   # $1=template $2=container $3=fallback
  local v
  # 容器不存在时 `docker inspect` 会先往 stdout 吐一个空行再失败，于是
  # `"$(... || echo missing)"` 拿到的是 "\nmissing" 而不是 "missing"，字符串比较
  # 会判真、把存在性检查骗过去（实测让 docker 的原生报错盖过了自己的提示）。
  v="$(probe docker inspect -f "$1" "$2" | squash)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$3"; fi
}
state_of()    { inspect_f '{{.State.Status}}' "$1" "missing"; }
policy_of()   { inspect_f '{{.HostConfig.RestartPolicy.Name}}' "$1" "-"; }
current_ctx() { probe kubectl config current-context | squash; }
node_of()     { printf '%s-control-plane' "$1"; }
kind_clusters() { probe kind get clusters | grep -vE '^No kind clusters found|^$' || true; }

# 数"真正就绪"的 pod。不能只 grep Running —— 那是 STATUS 列，`0/1 Running`
# （容器起来但探针没过）会被算成已就绪，刚 start 完立刻查必然误报全好。
ready_pods() {
  probe kubectl --context "$1" --request-timeout=5s get pods -n knative-serving --no-headers \
    | awk '{split($2,a,"/"); if (a[1] != "" && a[1] == a[2] && $3 == "Running") n++} END {print n+0}'
}
total_pods() {
  probe kubectl --context "$1" --request-timeout=5s get pods -n knative-serving --no-headers | grep -c . || true
}
node_ready() {  # → True / False / 空
  probe kubectl --context "$1" --request-timeout=5s get node "$2" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | squash
}

require_cluster() {
  local n; n="$(node_of "$1")"
  [ "$(state_of "$n")" != "missing" ] \
    || die "找不到集群 ${1}（节点容器 ${n} 不存在）。现有：$(kind_clusters | tr '\n' ' ')"
}

cmd_status() {
  local cur; cur="$(current_ctx)"
  local c n st pol mark ready pods tot
  for c in $(kind_clusters); do
    n="$(node_of "$c")"; st="$(state_of "$n")"; pol="$(policy_of "$n")"
    mark=""
    if [ "kind-$c" = "$cur" ]; then mark="   ← kubectl 当前 context"; fi
    echo "$c  [$st, 重启策略=$pol]$mark"
    if [ "$st" = "running" ]; then
      ready="$(node_ready "kind-$c" "$n")"
      pods="$(ready_pods "kind-$c")"; tot="$(total_pods "kind-$c")"
      note "节点 Ready=${ready:-?}   knative-serving 就绪 ${pods}/${tot}"
    fi
  done
}

cmd_start() {
  local c="$1"; require_cluster "$c"
  local n; n="$(node_of "$c")"
  if [ "$(state_of "$n")" = "running" ]; then
    note "$n 已经在运行"
  else
    note "启动 $n ..."
    docker start "$n" >/dev/null
  fi
  kubectl config use-context "kind-$c" >/dev/null
  note "kubectl context → kind-$c"

  local waited=0 nready=""
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    nready="$(node_ready "kind-$c" "$n")"
    if [ "$nready" = "True" ]; then note "节点 Ready（约 ${waited}s）"; break; fi
    sleep 5; waited=$((waited + 5))
  done
  if [ "$nready" != "True" ]; then
    echo "警告：${READY_TIMEOUT}s 内节点仍未 Ready，用 status 继续观察" >&2
    return 1
  fi

  # 节点 Ready 只说明 API server 能用了，Knative 的组件还要再等一会儿 ——
  # 这段窗口里 pod 是 `0/1 Running`。等齐再返回，这样 start 完就能直接干活。
  local pods tot waited2=0
  while [ "$waited2" -lt "$PODS_TIMEOUT" ]; do
    tot="$(total_pods "kind-$c")"
    if [ "$tot" = "0" ]; then
      note "该集群没有 knative-serving（没装 Knative？），跳过组件等待"
      return 0
    fi
    pods="$(ready_pods "kind-$c")"
    if [ "$pods" = "$tot" ]; then
      note "knative-serving 就绪 ${pods}/${tot}（约 ${waited2}s）"
      return 0
    fi
    sleep 5; waited2=$((waited2 + 5))
  done
  note "knative-serving 就绪 ${pods:-0}/${tot:-0}，还没全好，用 status 继续看"
}

cmd_stop() {
  local c="$1"; require_cluster "$c"
  local n; n="$(node_of "$c")"
  if [ "$(state_of "$n")" != "running" ]; then
    note "$n 已经是 $(state_of "$n") 状态，只确保它不会自动重启"
  fi
  # 顺序不能反：先关自动重启再停。否则 SIGKILL 的退出码 137 会被 on-failure
  # 策略当成失败，容器立刻被拉回来。
  docker update --restart=no "$n" >/dev/null
  note "restart policy → no"
  if [ "$(state_of "$n")" = "running" ]; then
    note "停止 ${n}（最多等 ${STOP_TIMEOUT}s；kind 节点通常退不干净，最后是退出码 137，属正常）"
    docker stop -t "$STOP_TIMEOUT" "$n" >/dev/null
  fi
  note "现在是 $(state_of "$n") / policy=$(policy_of "$n")"
  if [ "$(current_ctx)" = "kind-$c" ]; then
    local other; other="$(kind_clusters | grep -vx "$c" | head -1 || true)"
    echo
    echo "注意：kubectl 当前 context 仍指向 kind-${c}，之后 kubectl 命令会连不上。"
    if [ -n "$other" ]; then
      echo "  切走：kubectl config use-context kind-$other"
    else
      echo "  或先启动别的集群：knative-cluster.sh start <cluster>"
    fi
  fi
}

case "${1:-}" in
  status) cmd_status ;;
  start)  [ $# -ge 2 ] || die "start 需要集群名"; cmd_start "$2" ;;
  stop)   [ $# -ge 2 ] || die "stop 需要集群名";  cmd_stop  "$2" ;;
  *)      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' ; exit 1 ;;
esac
