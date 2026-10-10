# Knative Serving + Istio:网络层换 Gateway API,数据面用 ambient

> 实操环境:macOS (Apple Silicon) + colima + kind v0.32.0
> 集群 `knative-istio`:k8s v1.34.8
> 组件:Istio **1.31.1**(ambient profile)+ Knative Serving **v1.23.0** + **net-gateway-api v1.23.0**
>
> **本文所有命令与输出均为本机真实输出**(2026-10-10 实跑)。
>
> 承接基础篇 [`README.md`](README.md)(Kourier 版)。本篇把网络层换成
> Gateway API、把 Istio 作为 GatewayClass 的实现,数据面用 ambient 而不是 sidecar。

## 一、和 Kourier 那篇的三个不同点

| | Kourier 那篇 | 本篇 |
|---|---|---|
| Knative 的网络层 | `net-kourier` | `net-gateway-api` |
| Gateway 谁提供 | Kourier 自带的 Envoy | **Istio 提供的 GatewayClass `istio`** |
| 数据面 | 无 mesh | **Istio ambient**(ztunnel,**没有 sidecar**) |
| `ingress-class` | `kourier.ingress.networking.knative.dev` | `gateway-api.ingress.networking.knative.dev` |

注意这里**没有用 `net-istio`**。`net-istio` 和 `net-gateway-api` 是 Knative 两个并列的网络层实现:
前者让 Knative 直接写 Istio 的 `Gateway`/`VirtualService`(CRD),后者让 Knative 只写标准的
Gateway API 对象(`Gateway`/`HTTPRoute`),由 Istio 的 Gateway API 控制器去消费。
**本篇走的是后者**——Knative 侧不出现任何 Istio 专有 CRD。

## 二、对象关系

```
GatewayClass "istio"                    (Istio 装的,controllerName=istio.io/gateway-controller)
   ▲ 引用
   │
Gateway istio-system/knative-gateway          ← 外部入口,绑到 istio-ingressgateway 这个 Service
Gateway istio-system/knative-local-gateway    ← 集群内入口,绑到同名 ClusterIP Service
   ▲ 被引用
   │
config-gateway (ConfigMap, knative-serving)   ← 告诉 Knative 用上面这两个 Gateway
   ▲
   │
KIngress → HTTPRoute                          ← net-gateway-api 生成
   ▲
   │
KService helloworld-go → Route(URL: helloworld-go.demo.svc.cluster.local)
```

`net-gateway-api` 装好后会创建 `config-gateway`,**它内置的默认值就是 Istio 形状**——
这也是为什么选 Istio 时几乎不用额外配置:

```console
$ kubectl --context kind-knative-istio get configmap config-gateway -n knative-serving \
    -o jsonpath='{.data._example}' | tail -20
external-gateways: |
  - class: istio
    gateway: istio-system/knative-gateway
    service: istio-system/istio-ingressgateway
    supported-features:
    - HTTPRouteRequestTimeout
    proxy-protocol-enabled: false

local-gateways: |
  - class: istio
    gateway: istio-system/knative-local-gateway
    service: istio-system/knative-local-gateway
    supported-features:
    - HTTPRouteRequestTimeout
    proxy-protocol-enabled: false
```

> `service:` 那一行很关键:net-gateway-api 用它来探测数据面,而不是用 Gateway 的
> `status.addresses`。所以只要这里给了 `service`,即使 Gateway 因为拿不到地址而
> `PROGRAMMED=False`(见 9.1),路由依然能用。

## 三、ambient 是什么,为什么这里选它

ambient 把 mesh 拆成两层:

- **L4 层**由 **ztunnel** 负责——一个**每节点一个**的 DaemonSet,以 HBONE(HTTP/2 CONNECT over mTLS)
  接管 pod 的流量。**它不在你的 pod 里**,所以业务 pod 的容器列表和没上 mesh 时完全一样。
- **L7 层**按需由 **waypoint** 提供(本篇用不到,Knative 的路由由 ingress gateway 做)。

最直接的证据是 pod 里有哪些容器:

```console
$ REV=$(kubectl --context kind-knative-istio get pods -n demo --no-headers \
          | grep helloworld | awk '{print $1}' | head -1)
$ kubectl --context kind-knative-istio get pod -n demo "$REV" \
    -o jsonpath='{range .spec.containers[*]}  - {.name}{"\n"}{end}'
  - user-container
  - queue-proxy

$ kubectl --context kind-knative-istio get pod -n demo http-client \
    -o jsonpath='{range .spec.containers[*]}  - {.name}{"\n"}{end}'
  - curl
```

**没有 `istio-proxy`。** 换作 sidecar 模式,这两个 pod 里都会多出一个 `istio-proxy` 容器。
对 Knative 这种会在业务 pod 里注入 queue-proxy 的场景,少一层注入就少一处版本/启动顺序的纠缠。

> **kind 上的约束**:kind 节点共享宿主内核,ambient 的 eBPF 加速路径不可靠,
> **必须走 iptables 转发**(也就是 `istio-cni` DaemonSet 默认的方式)。
> 这也是 Istio ambient 在本地集群里的推荐配置。

## 四、环境准备

### 4.1 集群

沿用 [`kubernetes/kind/`](../kubernetes/kind/) 里那份带代理修复的配置,只换个名字和上下文:

```sh
export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock
cd kubernetes/kind
kind create cluster --name knative-istio \
  --config kind-config.yaml --image kindest/node:v1.34.8
```

k8s 1.34.8 落在 Istio 1.31 支持的 **1.32–1.36** 区间内。

### 4.2 给节点配 registry mirror(国内网络加速)

Knative 的镜像在 `gcr.io`,Istio 1.31 起把镜像从 Google Cloud 搬到了 Docker Hub。
在**节点内的 containerd** 上配镜像站,让 kubelet 按原始 ref 拉取、本地 ref 保持不变:

```sh
N=knative-istio-control-plane
docker exec $N sh -c 'cat >> /etc/containerd/config.toml <<"EOF"

  [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
      endpoint = ["https://gcr.m.daocloud.io", "https://gcr.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
      endpoint = ["https://ghcr.m.daocloud.io", "https://ghcr.io"]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["https://docker.m.daocloud.io", "https://registry-1.docker.io"]
EOF'
docker exec $N systemctl restart containerd
```

重启后**必须确认 CRI 插件还活着**——9.2 那个 `mirrors` / `config_path` 互斥的坑就会在这里露出来:

```sh
docker exec $N crictl images      # 能列出来就说明 CRI 正常
docker exec $N journalctl -u containerd --no-pager -n 30 | grep -c "failed to load plugin"   # 期望 0
```

镜像站是否真的生效,会在第五章装 Knative 时第一次拉取直接体现出来。

效果对比(同一台机器、同一条代理链路):

| 拉取路径 | 实测 |
|---|---|
| 直连 gcr.io(走代理) | 3 KB/s ~ 264 KB/s,21.9 MB 的 controller 镜像拉了 **1 小时 53 分** |
| 走镜像站 | **约 1.4 MB/s**,18.4 MB 的 autoscaler 镜像十几秒 |

拉下来之后本地 ref 仍然是 pod 清单要的那个 `@sha256:<index digest>`:

```console
$ docker exec $N ctr -n k8s.io images list | grep autoscaler
gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler@sha256:879da127b23db65d862cafa6b23fb987381d0e44150f0027d44e1f5aee83bde2  application/vnd.oci.image.index.v1+json  ...  linux/amd64,linux/arm/v7,linux/arm64,...
```

> **两个坑**:
> 1. containerd 2.x **不允许 `mirrors` 和 `config_path` 同时出现**,同时写会让 CRI 插件直接
>    加载失败(`unknown service runtime.v1.ImageService`)。二选一。
> 2. `containerd.service.d/` 下的代理 drop-in 是 bind mount,`sed -i` 会报
>    `Device or resource busy`(想改 `NO_PROXY` 得另想办法,或直接接受镜像站走代理)。

### 4.3 Gateway API CRDs

**必须在装 Istio 之前**。Istio 1.31 文档要求的是 v1.6.0 的 **experimental** channel:

```sh
kubectl --context kind-knative-istio apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/experimental-install.yaml
```

### 4.4 Istio:ambient profile + **手动打开入口网关**

```sh
# 钉住版本 —— 不设 ISTIO_VERSION 会装成 latest,而本文实测的是 1.31.1
curl -sL https://istio.io/downloadIstioctl -o /tmp/dl_istioctl
ISTIO_VERSION=1.31.1 sh /tmp/dl_istioctl              # 装到 ~/.istioctl/bin
export PATH="$HOME/.istioctl/bin:$PATH"
istioctl version --remote=false                       # client version: 1.31.1

istioctl install --context kind-knative-istio \
  --set profile=ambient \
  --set 'components.ingressGateways[0].enabled=true' \
  --set 'components.ingressGateways[0].name=istio-ingressgateway' \
  --skip-confirmation
```

> 上面这条 `istioctl install` 是**一条命令同时装 ambient 和入口网关**。它是否真的会生成
> 网关,不用起集群也能验:
>
> ```sh
> istioctl manifest generate --set profile=ambient \
>   --set 'components.ingressGateways[0].enabled=true' \
>   --set 'components.ingressGateways[0].name=istio-ingressgateway' \
>   | grep -c "name: istio-ingressgateway"      # 实测 17
> ```
>
> (拆成两步——先 `--set profile=ambient`,再加网关参数跑第二次——同样可行,本文第一次就是这么装的。)

**`--set components.ingressGateways[0].enabled=true` 不能省。** ambient profile 的定义里
明确把这个网关关掉了:

```yaml
# istio 仓库 manifests/profiles/ambient.yaml
spec:
  components:
    cni:
      enabled: true
    ztunnel:
      enabled: true
    ingressGateways:
    - name: istio-ingressgateway
      enabled: false      # ← 就是这个
```

而 net-gateway-api 的 `knative-gateway` 靠 `addresses: Hostname istio-ingressgateway`
绑定到这个已有的 Service 上,不装它就没有可绑的对象。

> zsh 用户注意:`--set 'components.ingressGateways[0]...'` **必须加引号**,
> 否则 `[0]` 会被当通配符,报 `no matches found`。

装完应该是这样:

```console
$ kubectl --context kind-knative-istio get pods -n istio-system
NAME                                    READY   STATUS    RESTARTS   AGE
istio-cni-node-x6qxx                    1/1     Running   0          2m48s
istio-ingressgateway-6988c76968-d9xqr   1/1     Running   0          23s
istiod-64fcd6dc89-82dd9                 1/1     Running   0          2m48s
ztunnel-2fnlc                           1/1     Running   0          2m22s

$ kubectl --context kind-knative-istio get gatewayclass
NAME             CONTROLLER                    ACCEPTED   AGE
istio            istio.io/gateway-controller   True       56s
istio-remote     istio.io/unmanaged-gateway    True       56s
istio-waypoint   istio.io/mesh-controller      True       56s
```

`istio` 这个 GatewayClass 就是要填进 `config-gateway` 的那个(`class: istio`)。

## 五、装 Knative Serving + net-gateway-api

```sh
V=knative-v1.23.0

kubectl --context kind-knative-istio apply -f \
  https://github.com/knative/serving/releases/download/$V/serving-crds.yaml
kubectl --context kind-knative-istio wait --for=condition=Established crd --all --timeout=180s
kubectl --context kind-knative-istio apply -f \
  https://github.com/knative/serving/releases/download/$V/serving-core.yaml

# 网络层:net-gateway-api(仓库同样在 knative-extensions 下)
kubectl --context kind-knative-istio apply -f \
  https://github.com/knative-extensions/net-gateway-api/releases/download/$V/net-gateway-api.yaml

kubectl --context kind-knative-istio patch configmap/config-network -n knative-serving \
  --type merge --patch '{"data":{"ingress-class":"gateway-api.ingress.networking.knative.dev"}}'
```

`knative-serving` 里应该是 **6 个 pod**(比 Kourier 那篇多一个 webhook):

```console
$ kubectl --context kind-knative-istio get pods -n knative-serving
NAME                                          READY   STATUS    RESTARTS   AGE
activator-56d698c974-2fq74                    1/1     Running   0          5m3s
autoscaler-69fcf466cb-j6h5f                   1/1     Running   0          5m3s
controller-5857b6bf55-fqtxf                   1/1     Running   0          5m3s
net-gateway-api-controller-5f6695d6b5-xxlkx   1/1     Running   0          5m2s
net-gateway-api-webhook-6b6f9bd74d-zr5wb      1/1     Running   0          5m2s
webhook-5cdb4c6879-qwmzd                      1/1     Running   0          5m3s
```

## 六、把网关联到 Istio

net-gateway-api 仓库里 `third_party/istio/` 就是为 Istio 准备的这三个资源,release tag 下可用:

```sh
BASE=https://raw.githubusercontent.com/knative-extensions/net-gateway-api/knative-v1.23.0/third_party/istio
kubectl --context kind-knative-istio apply \
  -f $BASE/203-local-gateway.yaml \
  -f $BASE/300-gateway.yaml \
  -f $BASE/300-gateway-local.yaml
```

三个文件各自的作用:

```yaml
# 300-gateway.yaml —— 外部入口,绑定到已存在的 istio-ingressgateway Service
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata: { name: knative-gateway, namespace: istio-system }
spec:
  gatewayClassName: istio
  addresses:
  - type: Hostname
    value: istio-ingressgateway
  listeners:
  - { name: default, port: 80, protocol: HTTP, allowedRoutes: { namespaces: { from: All } } }
  - name: tls
    port: 443
    protocol: TLS
    tls: { mode: Passthrough }
    allowedRoutes: { namespaces: { from: All } }
```

```yaml
# 300-gateway-local.yaml —— 集群内入口
kind: Gateway
metadata: { name: knative-local-gateway, namespace: istio-system }
spec:
  gatewayClassName: istio
  addresses: [{ type: Hostname, value: knative-local-gateway }]
  listeners:
  - { name: default, port: 80, protocol: HTTP, allowedRoutes: { namespaces: { from: All } } }
```

```yaml
# 203-local-gateway.yaml —— 集群内入口背后的 ClusterIP Service
kind: Service
metadata:
  name: knative-local-gateway
  namespace: istio-system
  labels: { experimental.istio.io/disable-gateway-port-translation: "true" }
spec:
  type: ClusterIP
  selector: { istio: ingressgateway }     # ← 复用 istio-ingressgateway 的 Pod
  ports: [{ name: http2, port: 80, targetPort: 8081 }]
```

`addresses` 里的 `Hostname` 就是 Istio 的**手工部署模式**:Gateway 不自己拉 Deployment,
而是绑到同名 Service 上。所以集群里只跑**一个** Envoy 数据面(`istio-ingressgateway`),
它同时服务外部和集群内两个 Gateway。

## 七、部署 demo 并登记到 ambient

**关键差异**:给命名空间打上 ambient 标签,这个命名空间里的 pod 就由 ztunnel 接管。

```sh
kubectl --context kind-knative-istio create namespace demo
kubectl --context kind-knative-istio label namespace demo istio.io/dataplane-mode=ambient

cat <<'EOF' | kubectl --context kind-knative-istio apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: helloworld-go
  namespace: demo
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/window: "20s"
    spec:
      containers:
        - image: ghcr.io/knative/helloworld-go:latest
          env:
            - name: TARGET
              value: "Knative on kind + Istio ambient"
EOF
```

客户端还是同一个命名空间里的常驻 curl pod:

```sh
cat <<'EOF' | kubectl --context kind-knative-istio apply -f -
apiVersion: v1
kind: Pod
metadata: { name: http-client, namespace: demo }
spec:
  containers:
    - { name: curl, image: curlimages/curl:latest, command: ["sleep", "infinity"] }
EOF
```

```console
$ kubectl --context kind-knative-istio get ksvc -n demo
NAME            URL                                           LATESTCREATED         LATESTREADY           READY   REASON
helloworld-go   http://helloworld-go.demo.svc.cluster.local   helloworld-go-00001   helloworld-go-00001   True
```

## 八、观测

### 8.1 链路对象

集群内那个 Service 和 Kourier 那篇是同一个套路,只是指向的网关不同:

```console
$ kubectl --context kind-knative-istio get svc -n demo
NAME                          TYPE           CLUSTER-IP      EXTERNAL-IP                                            PORT(S)
helloworld-go                 ExternalName   <none>          knative-local-gateway.istio-system.svc.cluster.local   80/TCP
helloworld-go-00001           ClusterIP      10.96.182.72    <none>                                                 80/TCP,443/TCP
helloworld-go-00001-private   ClusterIP      10.96.181.134   <none>                                                 80/TCP,443/TCP,9090/TCP,9091/TCP,8012/TCP
```

net-gateway-api 生成的 HTTPRoute:

```console
$ kubectl --context kind-knative-istio get httproute -A
NAMESPACE   NAME                                   HOSTNAMES                                                                                AGE
demo        helloworld-go.demo.svc.cluster.local   ["helloworld-go.demo","helloworld-go.demo.svc","helloworld-go.demo.svc.cluster.local"]   6s
```

完整路径:`http-client` → `helloworld-go.demo.svc.cluster.local`(ExternalName)→
`knative-local-gateway`(ClusterIP)→ istio-ingressgateway 的 Envoy → HTTPRoute →
revision 的 queue-proxy(或缩到 0 时转给 activator)。

### 8.2 缩容与冷启动

```console
$ kubectl --context kind-knative-istio exec -n demo http-client -- \
    curl -s -w "\n[HTTP %{http_code} in %{time_total}s]\n" http://helloworld-go.demo.svc.cluster.local
Hello Knative on kind + Istio ambient!

[HTTP 200 in 0.003830s]
```

空闲后自动缩容(节奏和 Kourier 那篇一致,说明**网关换掉不影响 scale-to-zero**):

```sh
# 每 10s 打一次状态,只在有变化时输出
last=""
for i in $(seq 1 16); do
  np=$(kubectl --context kind-knative-istio get pods -n demo --no-headers | grep -c helloworld)
  pa=$(kubectl --context kind-knative-istio get podautoscaler -n demo --no-headers \
        | awk '{print "desired="$2" actual="$3}')
  sm=$(kubectl --context kind-knative-istio get sks -n demo --no-headers | awk '{print $2}')
  l="revPods=$np $pa sks=$sm"
  [ "$l" != "$last" ] && { echo "[t=$((i*10))s] $l"; last="$l"; }
  sleep 10
done
```

```console
[t=10s] revPods=1 desired=1 actual=1 sks=Proxy
[t=30s] revPods=1 desired=0 actual=0 sks=Proxy
[t=60s] revPods=0 desired=0 actual=0 sks=Proxy
```

缩到 0 之后,`-private` Service 的后端空了,非 private 那个指向 activator:

```console
$ kubectl --context kind-knative-istio get endpointslice -n demo \
    -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .endpoints[*]}{.addresses[0]}{" "}{end}{"\n"}{end}'
helloworld-go-00001-b6kmv -> 10.244.0.9
helloworld-go-00001-private-b9z4v ->
```

`10.244.0.9` 正是 activator:

```console
$ kubectl --context kind-knative-istio get pods -n knative-serving -l app=activator -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP           NODE
activator-56d698c974-2fq74   1/1     Running   0          17m   10.244.0.9   knative-istio-control-plane
```

冷启动(**1.055s**,比 Kourier 那篇的 0.616s 慢一些,多出来的部分是 Istio 网关那一跳):

```console
$ kubectl --context kind-knative-istio exec -n demo http-client -- \
    curl -s -w "\n[HTTP %{http_code} total=%{time_total}s]\n" http://helloworld-go.demo.svc.cluster.local
Hello Knative on kind + Istio ambient!

[HTTP 200 total=1.055342s]
```

### 8.3 activator 依然是那个角色

```console
$ kubectl --context kind-knative-istio logs -n knative-serving -l app=activator --tail=400 \
    | grep -E "Set capacity" | tail -4
{"logger":"activator","caller":"net/throttler.go:328","message":"Set capacity to 0 (backends: 0, index: 0/1)","knative.dev/key":"demo/helloworld-go-00001"}
{"logger":"activator","caller":"net/throttler.go:328","message":"Set capacity to 2147483647 (backends: 1, index: 0/1)","knative.dev/key":"demo/helloworld-go-00001"}
{"logger":"activator","caller":"net/throttler.go:328","message":"Set capacity to 0 (backends: 0, index: 0/1)","knative.dev/key":"demo/helloworld-go-00001"}
```

ServerlessService 依然是 `Proxy` 模式——**流量全程经过 activator,和网络层选谁无关**:

```console
$ kubectl --context kind-knative-istio get sks -n demo      # revision 活跃时
NAME                  MODE    ACTIVATORS   SERVICENAME           PRIVATESERVICENAME            READY   REASON
helloworld-go-00001   Proxy   4            helloworld-go-00001   helloworld-go-00001-private   True
```

> 缩到 0 的那段时间里 SKS 会显示 `READY=Unknown / NoHealthyBackends`(private service
> 没有后端),revision 起来后回到 `True`。

### 8.4 ambient 视角:ztunnel 是怎么看待这些 pod 的

```console
$ istioctl ztunnel-config workloads --context kind-knative-istio
NAMESPACE          POD NAME                                            ADDRESS     NODE                        WAYPOINT PROTOCOL
default            kubernetes                                          172.18.0.3                              None     TCP
demo               helloworld-go-00001-deployment-864b54cbc5-52l64     10.244.0.16 knative-istio-control-plane None     HBONE
demo               http-client                                         10.244.0.15 knative-istio-control-plane None     HBONE
istio-system       istio-cni-node-x6qxx                                10.244.0.5  knative-istio-control-plane None     TCP
istio-system       istio-ingressgateway-6988c76968-d9xqr               10.244.0.8  knative-istio-control-plane None     TCP
istio-system       istiod-64fcd6dc89-82dd9                             10.244.0.6  knative-istio-control-plane None     TCP
istio-system       ztunnel-2fnlc                                       10.244.0.7  knative-istio-control-plane None     TCP
```

这张表把 ambient 的作用范围说得很清楚:

- `demo` 命名空间被打上了 `istio.io/dataplane-mode=ambient`,所以它的两个 pod
  **PROTOCOL=HBONE**,由 ztunnel 以 mTLS 接管——**包括那个没有 sidecar 的 revision pod**。
- `istio-system` 没有登记 ambient,所以 istiod / 网关 / ztunnel 自己都是 `TCP`(普通明文)。

### 8.5 关于 mTLS,一个诚实的说明

**这个拓扑里没有端到端的 mTLS,原因是入口网关不在 ambient 里。** 这点可以从 ztunnel
自己的访问日志里读出来:把日志级别调到 debug,再从客户端发一次请求。

```sh
istioctl ztunnel-config log ztunnel-2fnlc.istio-system --level debug
kubectl --context kind-knative-istio exec -n demo http-client -- \
  curl -s -o /dev/null http://helloworld-go.demo.svc.cluster.local
```

```console
$ kubectl --context kind-knative-istio logs -n istio-system ztunnel-2fnlc \
    | grep "connection complete" | tail -1
access	connection complete	src.addr=10.244.0.15:36406 src.workload="http-client" src.namespace="demo" \
  src.cluster="Kubernetes" dst.addr=10.244.0.8:8081 \
  dst.service="knative-local-gateway.istio-system.svc.cluster.local" \
  dst.workload="istio-ingressgateway-6988c76968-d9xqr" dst.namespace="istio-system" \
  dst.cluster="Kubernetes" direction="outbound" bytes_sent=100 bytes_recv=214 duration="1561ms"
```

这一行同时说明了两件事:

- **ztunnel 确实在接管 `http-client`**(`src.workload="http-client"`,连接由它记录)——ambient 生效了,
  而且这个 pod 里没有 sidecar。
- **这一跳没有封 HBONE**:目标是 `10.244.0.8:8081`,网关 Pod 的**真实端口**。若目的端也在
  ambient 里,ztunnel 会把流量封到对端 ztunnel 的 **15008**(HBONE 端口)上;走 8081
  就意味着是明文。网关到 revision 那一跳同理(源端不在 mesh)。

(顺带确认了 `knative-local-gateway` 那个 Service 的 `targetPort: 8081` 是真的在用。)

> 看完记得把日志级别调回去:`istioctl ztunnel-config log ztunnel-2fnlc.istio-system --level info`

所以 ambient 在这里的价值不是"加密这几跳",而是:

1. 命名空间打一个 label 就纳入 mesh,**业务 pod 完全无感**(没有 sidecar,queue-proxy 不受影响);
2. 拿到 L4 的身份与策略能力,后续要加 `AuthorizationPolicy` 不用改工作负载;
3. 需要 L7 能力时再单独给某个服务挂 waypoint,而不是全量注入 sidecar。

想让网关那一跳也加密,就得把 `istio-system` 也登记进 ambient,或者改用 sidecar 模式给网关注入——
这两种都会把控制面本身卷进来,不是本地实验该顺手做的事,本文不做。

## 九、排障

### 9.1 外部 Gateway 一直 `PROGRAMMED=False`(kind 没有 LoadBalancer)

```console
$ kubectl --context kind-knative-istio get gateway -A
NAMESPACE      NAME                    CLASS   ADDRESS                                                PROGRAMMED   AGE
istio-system   knative-gateway         istio                                                          False        3m7s
istio-system   knative-local-gateway   istio   knative-local-gateway.istio-system.svc.cluster.local   True         3m7s
```

原因写在 condition 里,非常明确:

```console
$ kubectl --context kind-knative-istio get gateway knative-gateway -n istio-system \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'
Accepted=True: Resource accepted
Programmed=False: Assigned to service(s) istio-ingressgateway.istio-system.svc.cluster.local:443 and istio-ingressgateway.istio-system.svc.cluster.local:80, but failed to assign to all requested addresses: address pending for hostname "istio-ingressgateway.istio-system.svc.cluster.local"
ResolvedRefs=True: All references resolved
```

拆开看:Istio **已经**把 Gateway 绑到了 `istio-ingressgateway` 这个 Service(80 和 443 都绑上了),
但它要往 `status.addresses` 里回报地址,而 kind 上 `istio-ingressgateway` 是
`type: LoadBalancer`、EXTERNAL-IP 永远 `<pending>` → 地址分配不上 → `Programmed=False`。
`knative-local-gateway` 背后是 ClusterIP,所以是 `True`。

**对我们没有影响**:`config-gateway` 里显式写了 `service:`,net-gateway-api 不依赖这个 status
(见第二章的注解)。真要让它变 `True`、并且从笔记本访问,就需要一个 LoadBalancer 实现
(cloud-provider-kind 或 MetalLB)——本机那套 cloud-provider-kind 要靠 sudo 前台进程维持,
本文刻意不碰。

### 9.2 containerd:`mirrors` 和 `config_path` 不能同时设

配镜像站时如果两个都写,containerd 会**静默地不加载 CRI 插件**,然后所有 `crictl` 命令报:

```
validate CRI v1 image API ... rpc error: code = Unimplemented desc = unknown service runtime.v1.ImageService
```

日志里才有真正的原因:

```console
$ docker exec $N journalctl -u containerd | grep "failed to load plugin"
level=warning msg="failed to load plugin" error="unable to load CRI image service plugin dependency: invalid cri image config: `mirrors` cannot be set when `config_path` is provided" id=io.containerd.grpc.v1.cri
```

二选一即可。另外 `containerd.service.d/` 下的代理 drop-in 是 bind mount,`sed -i` 会报
`Device or resource busy`,改它要用别的方式(直接 `>` 覆写),而且注意**别改到仓库里的源文件**。

### 9.3 zsh 会把 `--set` 里的 `[0]` 当通配符

```console
$ istioctl install --set components.ingressGateways[0].enabled=true ...
(eval):1: no matches found: components.ingressGateways[0].enabled=true
```

加引号:`--set 'components.ingressGateways[0].enabled=true'`。

### 9.4 反例:这套组合里最容易漏的三步

1. **Gateway API CRDs 必须在 Istio 之前装**(4.3)。
2. **ambient profile 不装入口网关,必须 `--set components.ingressGateways[0].enabled=true`**(4.4)。
3. **`third_party/istio` 那三个资源要手动 apply**(第六章)——net-gateway-api 不会替你建 Gateway。

漏掉任何一个,现象都是 KService 一直 `NotReady`,而 Knative 侧不一定给出指向真正原因的报错。

## 十、清理

按"删到什么程度"分三档,按需取用。

**只删实验负载,保留整套环境**(想再跑一遍 demo 就用这个):

```sh
kubectl --context kind-knative-istio delete namespace demo
```

**卸掉 Istio,保留集群**(想换个网络层/数据面再试):

```sh
export PATH="$HOME/.istioctl/bin:$PATH"
istioctl uninstall --context kind-knative-istio --purge -y
kubectl --context kind-knative-istio delete namespace istio-system   # --purge 不会删命名空间
```

**整个删掉**:

```sh
kubectl --context kind-knative-istio delete namespace demo
kind delete cluster --name knative-istio
```

两点说明:

- **Gateway API 的 CRD 是集群级的**,`istioctl uninstall` 不会带走它们。想一并清掉就删掉
  当初 apply 的那份 bundle(`kubectl delete -f .../v1.6.0/experimental-install.yaml`)——
  如果它卡住不返回,那是因为还有对象在引用这些 CRD。
- `kind delete cluster` 会连节点容器一起删,所以第四章对节点 containerd 做的镜像站改动
  也随之一并消失,不用手动回收。colima 里那份 dockerd 代理 drop-in 和
  [`kubernetes/kind/`](../kubernetes/kind/) 里的修复文件则要留着,下次建集群直接复用。

## 相关

- [`README.md`](README.md) —— Kourier 版,以及 kind 代理、gcr.io 拉取慢等环境问题的完整记录
- [`kubernetes/kind/`](../kubernetes/kind/) —— kind 集群配置与节点内代理修复文件
- [net-gateway-api](https://github.com/knative-extensions/net-gateway-api) —— `third_party/istio/` 的来源
- [Istio ambient 安装](https://istio.io/latest/docs/ambient/install/) / [Gateway API 入口](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/)
- [Knative:安装网络层(Gateway API 是 beta)](https://knative.dev/docs/install/yaml-install/serving/install-serving-with-yaml/)
