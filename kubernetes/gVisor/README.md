# gVisor 在 kind 集群中的启用与排障

> 实操环境:macOS (Apple Silicon, aarch64) + Podman Machine + kind 集群
> (`agent-sandbox-control-plane`,containerd v2.3.1),runsc release-20260810.0
>
> 对应英文版仓库文档:`k8s-agent-sandbox/docs/gvisor-kind-setup.md`

## 一、gVisor 是什么,为什么 kind 上可行

- gVisor 是**纯用户态内核**:应用的系统调用被拦截,由 gVisor 自己实现的
  Linux 内核(userspace)处理,容器不直接接触宿主机内核。
- 与 Kata Containers 的关键区别:**不需要 KVM/硬件虚拟化**。Kata 每个 pod
  起一个真 VM,必须有 `/dev/kvm`,所以 kind 节点容器里跑不了(Kata 的
  guest-agent 握手在容器化节点内无法完成);gVisor 默认用 **ptrace 平台**,
  只要 Linux 环境即可——因此 macOS 上也能用:runsc 跑在承载容器的 Linux
  VM(Podman Machine / Docker Desktop)里。
- 注意:runsc 是 **Linux 二进制**,必须装进集群**节点容器内部**,不是在
  macOS 宿主上直接跑。

## 二、前置条件检查

```sh
# 架构 —— 决定下载哪个 runsc 版本
podman exec agent-sandbox-control-plane uname -m      # aarch64 / x86_64

# ptrace 平台要求 yama ptrace_scope = 0
podman exec agent-sandbox-control-plane sysctl kernel.yama.ptrace_scope

# containerd 版本(kind 新版节点是 2.x)
podman exec agent-sandbox-control-plane containerd --version
```

- 实测本机节点:架构 `aarch64` ✓,`ptrace_scope = 0` ✓,containerd `2.3.1` ✓
- 若 ptrace_scope 不是 0:
  `podman exec <node> sysctl -w kernel.yama.ptrace_scope=0`

## 三、方案 A:装进运行中的 kind 节点(快速路径)

### 1. 下载 runsc + containerd shim(务必校验!)

gVisor 发布桶按架构分目录:https://storage.googleapis.com/gvisor/releases/release/latest/<arch>/
其中 `<arch>` ∈ {`aarch64`, `x86_64`}(**新版已不是 `runsc_arm64` 后缀,
而是 `aarch64/runsc` 子目录!**)。

```sh
BASE=https://storage.googleapis.com/gvisor/releases/release/latest/aarch64
curl -fsSL -o runsc "$BASE/runsc"
curl -fsSL -o containerd-shim-runsc-v1 "$BASE/containerd-shim-runsc-v1"

# 校验(文件名必须与 .sha512 内记录的名字完全一致!)
curl -fsSL -o runsc.sha512 "$BASE/runsc.sha512"
curl -fsSL -o shim.sha512 "$BASE/containerd-shim-runsc-v1.sha512"
sha512sum -c runsc.sha512
sha512sum -c shim.sha512
```

健康体积参考:aarch64 runsc 约 98MB,shim 约 41MB。**几 MB 的 runsc 必是坏文件。**

### 2. 传入节点

```sh
podman cp runsc agent-sandbox-control-plane:/usr/local/bin/runsc
podman cp containerd-shim-runsc-v1 agent-sandbox-control-plane:/usr/local/bin/containerd-shim-runsc-v1
podman exec agent-sandbox-control-plane chmod +x /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1

# 冒烟测试
podman exec agent-sandbox-control-plane runsc --version
# 期望输出:runsc version release-20260810.0
```

### 3. containerd 注册 runsc runtime + 重启

```sh
podman exec agent-sandbox-control-plane sh -c '
  printf "\n[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runsc]\n  runtime_type = \"io.containerd.runsc.v1\"\n" >> /etc/containerd/config.toml
  systemctl restart containerd'
```

> 用追加方式改配置,不要覆盖 kind 原生的 config.toml;containerd 2.x 如果
> 整个重写文件要用 `version = 3` 头。重启 containerd 会短暂重建节点上的 pod。

### 4. 创建 RuntimeClass

handler 必须与 containerd 里注册的 runtime 名(`runsc`)完全一致:

```sh
kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
```

### 5. 验证

```sh
kubectl run gvisor-test --image=busybox --restart=Never --runtime-class=gvisor --command -- sleep 3600
kubectl get pod gvisor-test -o jsonpath='{.spec.runtimeClassName}'
kubectl exec gvisor-test -- dmesg | head -1    # 输出 gVisor 内核横幅
podman exec agent-sandbox-control-plane ps aux | grep -E 'runsc|containerd-shim'  # 不是 runc
```

## 四、方案 B:可复现(自定义节点镜像)

运行中节点里装的二进制,重建集群就没了。可复现做法:

`Dockerfile`(按节点架构构建,如 Apple Silicon 用 `docker build --platform linux/arm64`):

```dockerfile
FROM kindest/node:v1.31.0
COPY runsc /usr/local/bin/runsc
COPY containerd-shim-runsc-v1 /usr/local/bin/containerd-shim-runsc-v1
RUN chmod +x /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1 \
    && sysctl -w kernel.yama.ptrace_scope=0
```

`kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: gvisor-kind-node:latest
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
    runtime_type = "io.containerd.runsc.v1"
```

## 五、与 agent-sandbox 集成

```sh
kubectl apply -k examples/vscode-sandbox/overlays/gvisor
```

原理:Sandbox 的 `podTemplate.spec.runtimeClassName: gvisor` 即可,和普通
pod 同一机制。

> ⚠️ gVisor/Kata 运行时下,`kubectl port-forward` 直连沙箱 pod 不兼容,
> 需要通过 Sandbox Router 访问(见仓库 gvisor-isolation 文档)。

## 六、排障(本环境实操踩坑实录)

### 6.1 下载失败 / 校验不匹配

**坑 A:kind 节点连不上 Google 系域名。** 症状:节点内 `curl` 秒退
(`Could not connect` / `i/o timeout`),宿主机同命令正常。原因:节点流量走
的出口对 GCP(`storage.googleapis.com`、`*.docker.pkg.dev`)不通。
**解法**:在宿主机(或任何能访问的机器)下载 → sha512 校验 → `podman cp`
传进节点。

**坑 B:代理吐损坏内容。** 症状:HTTP 200 但文件体积异常(如 runsc 只有
3.4MB)、sha512 对不上。代理流式传输时可能返回残缺响应。**解法**:重下 +
校验,或 `curl --noproxy '*'` 直连试试。

**坑 C:`sha512sum -c` 报 "No such file or directory"。** 这是**文件名坑**
不是下载问题:`sha512sum -c` 会找 `.sha512` 文件内部记录的那个文件名,
必须和本地文件名一致(比如校验文件里写 `containerd-shim-runsc-v1`,本地
文件就不能叫 `shim`)。本次实操在这里误判了很久。

### 6.2 runsc 启动 Segmentation fault

= **二进制损坏**(截断/代理污染)。重下并校验;健康 runsc 是几十 MB 的
ELF,几 MB 必是坏的。

### 6.3 pod 卡在 ContainerCreating

- RuntimeClass 的 `handler` 与 containerd runtime 名不匹配(必须都是
  `runsc`)
- 节点里二进制缺失:`podman exec <node> runsc --version` 验证;重建集群后
  节点内安装会丢失(用方案 B)
- containerd 没加载新配置:改完必须 `systemctl restart containerd`,看
  `kubectl describe pod` 的 Events 和 `journalctl -u containerd`
- ptrace_scope 不是 0:gVisor ptrace 平台无法 attach

### 6.4 containerd 2.x 兼容性

kind 新版本节点是 containerd 2.x。gVisor shim 与 containerd 2.0 曾有兼容
问题(症状:`kubectl delete` 卡死、pod 无法销毁),**containerd 2.1+ 已修复**
(见 containerd/containerd#11708、#11091)。本机 2.3.1 无此问题。

### 6.5 镜像拉取失败(与 gVisor 无关的 kind 网络坑)

kind 在**创建集群时**把宿主机的 `HTTP(S)_PROXY` 快照进节点的 systemd。
如果代理只监听宿主机回环(如 `127.0.0.1:7890`),节点内是死代理,任何外网
镜像拉取报:`proxyconnect tcp: dial tcp 127.0.0.1:7890: connect: connection refused`。
解法:不带代理变量重建集群(`env -u HTTP_PROXY ... kind create cluster`),
或宿主机拉镜像后 `kind load`。

### 6.6 如何确认 pod 真的在 gVisor 里

1. `kubectl get pod <pod> -o jsonpath='{.spec.runtimeClassName}'` → `gvisor`
2. pod 内 `dmesg | head -1` 显示 gVisor 内核横幅;`/proc/version` 与宿主不同
3. 节点上 `ps aux | grep runsc` 看到 gVisor shim,而不是 `containerd-shim-runc-*`

## 七、备选方案

- **minikube**:`minikube addons enable gvisor` 一条命令(官方 quickstart 路径)
- **GKE Sandbox**:托管节点池自带 gVisor
- **Kata**:需要真 KVM,macOS 本地不可行(需 AKS/云 VM/裸金属,见仓库
  kata-aks 示例)

## 参考链接

- gVisor 官方:https://gvisor.dev/
- containerd quick start:https://gvisor.dev/docs/user_guide/containerd/quick_start/
- 发布桶:https://storage.googleapis.com/gvisor/releases/release/latest/
- containerd shim 兼容问题:https://github.com/containerd/containerd/issues/11708
- agent-sandbox gVisor 集成:https://agent-sandbox.sigs.k8s.io/docs/use-cases/gvisor-isolation/
