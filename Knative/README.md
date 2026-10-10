# Knative Serving 在 kind 上的安装与 Scale-to-Zero 观测

> 实操环境:macOS (Apple Silicon, aarch64) + colima + kind v0.32.0
> 集群 `knative`:k8s v1.34.8(kindest/node:v1.34.8),containerd 2.3.1
> 组件:Knative Serving `knative-v1.23.0` + net-kourier `knative-v1.23.0`
>
> **本文所有命令与输出均为本机真实输出**(2026-10-10 实跑)。

这个实验的目标:在笔记本上用 kind 跑一个最小的 Knative Serving,然后
**从集群内部发 curl**,观察 activator 把 revision 从 0 拉到 1、再缩回 0。

不需要 Istio,不需要 DNS,不需要 LoadBalancer,也不需要 `port-forward`。

## 一、先明确一个前提:不用 Istio ≠ 不用网络层

Knative Serving **自己不做数据面**。它只定义了一个抽象(`KIngress` 规范),
真正的路由必须由一个"网络层"实现来提供,可选的就四个:

| 实现 | `ingress-class` 取值 | 说明 |
|---|---|---|
| net-istio | `istio.ingress.networking.knative.dev` | **默认值**,最重 |
| net-kourier | `kourier.ingress.networking.knative.dev` | 官方为 Knative 定制,最轻 |
| net-contour | `contour.ingress.networking.knative.dev` | 依赖 Contour |
| net-gateway-api | `gateway-api.ingress.networking.knative.dev` | beta,还要另装 Gateway 实现 |

`config-network` 里 `ingress-class` 的默认值就是 istio。**不装任何实现的话,
`Ingress` 资源没人处理,KService 会永远 `NotReady`——没有"不装网络层"这个选项。**

所以"不用 Istio"的正确做法是换一个轻的实现。本文选 **Kourier**:没有 CRD、
没有 sidecar,只有两个 Deployment(`net-kourier-controller` + `kourier`),
是官方文档里"拿不准就选它"的那个。

## 二、为什么这个实验连 DNS 和 LoadBalancer 都不需要

Knative 从 **v1.8** 起把 KService 的默认域名改成了 `svc.cluster.local` 后缀,
也就是**默认就只有集群内可达**。所以:

- `kubectl get ksvc` 给出的 URL 直接就是 `http://helloworld-go.demo.svc.cluster.local`
- 不需要 sslip.io 这类 magic DNS,不需要改 `/etc/hosts`,不需要 `serving-default-domain.yaml`
- 不需要 LoadBalancer:kourier 那个 `type: LoadBalancer` 的 Service 在 kind 上会一直
  `<pending>`,但**我们用不到它**——集群内流量走的是 `kourier-internal`(ClusterIP)
- 于是也完全绕开了 `cloud-provider-kind` 那套需要 sudo 前台进程维持的东西

`config-domain` 这个 ConfigMap 默认**只有一段示例注释,没有任何真实配置**
(唯一的键就是 `_example`),但 ksvc 的 URL 依然是 `svc.cluster.local` 结尾——
说明这个域名是 Knative 内置的默认值,不是在这里配出来的:

```console
$ kubectl --context kind-knative get configmap config-domain -n knative-serving -o jsonpath='{.data}' \
    | python3 -c 'import sys,json; print("data keys =", list(json.load(sys.stdin)))'
data keys = ['_example']

$ kubectl --context kind-knative get route helloworld-go -n demo -o jsonpath='{.status.url}'
http://helloworld-go.demo.svc.cluster.local
```

### 集群内请求走的是哪条路

这是本实验最值得先搞清楚的一张图:

```
client pod (demo/http-client)
    │  curl http://helloworld-go.demo.svc.cluster.local
    ▼
K8s Service "helloworld-go"  (demo 命名空间, 类型是 ExternalName)
    │  CNAME -> kourier-internal.kourier-system.svc.cluster.local
    ▼
kourier-internal (ClusterIP) -> kourier gateway (Envoy)
    │
    │  实测这一跳之后流量**始终**经过 activator:
    │  ServerlessService 的 MODE 是 Proxy(min-scale=0 时就是这样),
    │  revision 活跃与否都绕不开它
    ▼
activator (knative-serving)
    │  revision 缩到 0: 先把请求挂住、触发扩容,等 pod ready 再转发
    │  revision 已就绪: 直接转发
    ▼
revision pod (user-container + queue-proxy 两个容器)
```

两个容易踩的认知点,实测确认:

1. **`<ksvc>` 这个 Service 不是普通的 ClusterIP,而是 `ExternalName`**,
   它只是个 CNAME 指向 `kourier-internal`,本身没有 endpoints:

   ```console
   $ kubectl get svc -n demo
   NAME            TYPE           CLUSTER-IP   EXTERNAL-IP                                         PORT(S)
   helloworld-go   ExternalName   <none>       kourier-internal.kourier-system.svc.cluster.local   80/TCP
   ```

2. **真正会"切换"的是 revision 的 `-private` Service**。
   `helloworld-go-00001-private` 的 endpoints 在 revision 活跃时指向业务 pod,
   缩到 0 之后变成空;而 `helloworld-go-00001`(非 private)的 endpoints
   **始终指向 activator**。因为默认 `min-scale=0`,activator 会一直留在数据路径上:

   ```console
   $ kubectl get serverlessservice -n demo
   NAME                  MODE    ACTIVATORS   SERVICENAME           PRIVATESERVICENAME            READY
   helloworld-go-00001   Proxy   4            helloworld-go-00001   helloworld-go-00001-private   True
   ```

   `MODE=Proxy` 就是"流量经过 activator"的意思。本实验全程观测到的都是 Proxy
   (`Serve` 模式——网关直连 queue-proxy、把 activator 摘出去——只在 revision
   被钉住不退场时才出现,比如 `min-scale` 设成正数)。

## 三、本机环境准备(四个坑)

### 3.1 colima 的资源:默认 2C/2G 装不下

本机 colima 默认 profile 是 **2 CPU / 2 GiB**。Knative 官方对单节点集群的建议是
**6 CPU / 6 GB / 30 GB 磁盘**(quickstart 那套放宽到 3C/3G)。
起步至少要 4C/6G,否则控制面 pod 会一直 Pending/OOM:

```sh
colima start --cpu 4 --memory 6
```

```console
$ colima list
PROFILE    STATUS     ARCH       CPUS    MEMORY    DISK      RUNTIME    ADDRESS
default    Running    aarch64    4       6GiB      100GiB    docker
```

宿主是 10C/16G,给 4C/6G 比较合适;真遇到 OOM 再往上加。

### 3.2 代理第一层:colima VM 里的 dockerd(拉 `kindest/node`)

本机 mac 开了系统代理 `127.0.0.1:7890`。`colima start` 会把这个代理
**注入到 VM 的 shell 环境**里(并正确地把 `127.0.0.1` 换写成 VM 里可达的宿主地址
`192.168.5.2`),但**不会注入到 dockerd**。结果是:

- VM 里 `curl` 通,`docker pull` 不通,报
  `Head "https://registry-1.docker.io/v2/.../manifests/...": EOF`
- `kind create cluster` 会在拉 `kindest/node` 这一步直接失败

修复:给 dockerd 加一个 systemd drop-in,指向宿主网关。

```sh
colima ssh -- sudo sh -c 'mkdir -p /etc/systemd/system/docker.service.d && \
  printf "%s\n" "[Service]" \
    "Environment=\"HTTP_PROXY=http://host.lima.internal:7890\"" \
    "Environment=\"HTTPS_PROXY=http://host.lima.internal:7890\"" \
    "Environment=\"NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,10.244.0.0/16,10.96.0.0/16,172.17.0.0/16,172.18.0.0/16,.svc,.svc.cluster.local\"" \
    > /etc/systemd/system/docker.service.d/http-proxy.conf && \
  systemctl daemon-reload && systemctl restart docker'
```

验证:

```console
$ colima ssh -- sh -c 'tr "\0" "\n" < /proc/$(systemctl show docker -p MainPID --value)/environ | grep -i proxy'
HTTPS_PROXY=http://host.lima.internal:7890
HTTP_PROXY=http://host.lima.internal:7890
```

> 注意 `host.lima.internal` 是 lima/colima 提供的宿主别名(实测解析为 `192.168.5.2`,
> 也就是 VM 网关)。Docker Desktop 下对应的是 `host.docker.internal`。
> 重启 colima 后这个 drop-in 依然生效(它在 VM 磁盘里,不在容器里)。

### 3.3 代理第二层:kind 节点里的 containerd / kubelet(拉业务镜像)

节点容器内看到的 `127.0.0.1` 是节点自己的 loopback,不是 mac。修复文件在
[`kubernetes/kind/`](../kubernetes/kind/):`kind-config.yaml` + `kind-proxy.conf`,
建集群时通过 `extraMounts` 把 drop-in 挂进节点,代理指向 `host.docker.internal`。

**这里有一个曾经的 bug,已修**:原来的 `kind-proxy.conf` 里写的是占位符
`__HOST_IP__`,注释以为 kind 会自动替换成宿主 IP。**kind 没有这个替换机制**,
字符串原样落进节点,kubelet 于是去解析一个叫 `__HOST_IP__` 的域名,节点注册不上,
`kubeadm init` 报 `error execution phase mark-control-plane: nodes "..." not found`。
现在两个文件都改成写死 `host.docker.internal`。

另外 `NO_PROXY` 必须覆盖集群自己的网段——**尤其别漏 `172.18.0.0/16`**,
那是 kind 节点的 docker 网桥,kubelet 连 API server 就走这里:

```ini
NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,10.244.0.0/16,10.96.0.0/16,172.17.0.0/16,172.18.0.0/16,192.168.0.0/16,.svc,.svc.cluster.local
```

### 3.4 `DOCKER_HOST` 指向 podman,而 kind 只认它

本机 shell profile 里 `DOCKER_HOST` 固定指向 podman 的 socket,而 docker 的默认
context 也可能飘。kind 走的是 `DOCKER_HOST`,所以**每条 kind/docker 命令都要显式指定
colima 的 socket**:

```sh
export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock
```

不设的话典型报错是 `failed to connect to the docker API at
unix:///var/folders/.../podman-machine-default-api.sock`。

## 四、建 kind 集群

`kind-config.yaml` 里的 `hostPath` 是相对**当前工作目录**解析的,所以必须
`cd kubernetes/kind/` 之后再执行。k8s 版本固定到 Knative v1.23 要求的下限 1.34:

```sh
export DOCKER_HOST=unix://$HOME/.colima/default/docker.sock
cd kubernetes/kind
kind create cluster --name knative \
  --config kind-config.yaml \
  --image kindest/node:v1.34.8
```

```console
$ kubectl --context kind-knative get nodes -o wide
NAME                    STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION      CONTAINER-RUNTIME
knative-control-plane   Ready    control-plane   21s   v1.34.8   172.18.0.2    <none>        Debian GNU/Linux 13 (trixie)   6.8.0-117-generic   containerd://2.3.1
```

等节点 Ready(刚建好时有十几秒 `NotReady`,是 CNI 在起):

```sh
for i in $(seq 1 40); do
  s=$(kubectl --context kind-knative get node knative-control-plane \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  [ "$s" = "True" ] && { echo "Ready after ~$((i*3))s"; break; }
  sleep 3
done
kubectl --context kind-knative get nodes -o wide
```

顺手确认 3.3 那份代理配置真的落进了节点——**这一步能省掉后面所有的"为什么镜像拉不动"**:

```sh
docker exec knative-control-plane cat /etc/systemd/system/kubelet.service.d/http-proxy.conf \
  | grep -c host.docker.internal     # 期望非 0
```

再验证节点能不能真的拉外网镜像(这一层不通的话后面全是白费)。
镜像已在本地时 `crictl` 直接回一句 `Image is up to date for <id>`;首次拉取时
进度打在 stderr,同样以这一行收尾:

```console
$ docker exec knative-control-plane crictl pull ghcr.io/knative/helloworld-go:latest
Image is up to date for sha256:c512c8596b0d72c90919ff7564712a3cc2441f85c07790d0f1c1c3f202bc6285
```

拉不动的话报错形如 `failed to do request: Head "https://...": EOF`,
对应 3.3 里的节点代理配置。

## 五、安装 Knative Serving + Kourier

四条命令,顺序不能换(CRD 要先 established,core 才有依赖):

```sh
V=knative-v1.23.0

# 1. Serving CRDs
kubectl --context kind-knative apply -f \
  https://github.com/knative/serving/releases/download/$V/serving-crds.yaml

# 等 CRD 建立
kubectl --context kind-knative wait --for=condition=Established crd --all --timeout=180s

# 2. Serving 控制面
kubectl --context kind-knative apply -f \
  https://github.com/knative/serving/releases/download/$V/serving-core.yaml

# 3. 网络层:Kourier(注意仓库在 knative-extensions 下)
kubectl --context kind-knative apply -f \
  https://github.com/knative-extensions/net-kourier/releases/download/$V/kourier.yaml

# 4. 告诉 Knative 用 kourier 处理 Ingress
kubectl --context kind-knative patch configmap/config-network -n knative-serving \
  --type merge --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
```

起来之后应该有 **6 个 pod**:`knative-serving` 里 5 个,`kourier-system` 里 1 个。

```console
$ kubectl --context kind-knative get pods -n knative-serving
NAME                                      READY   STATUS    RESTARTS   AGE
activator-56d698c974-w7564                1/1     Running   0          13h
autoscaler-69fcf466cb-v4kqn               1/1     Running   0          13h
controller-5857b6bf55-cmf7d               1/1     Running   0          10s
net-kourier-controller-5d74dfdd6f-ljc49   1/1     Running   0          10s
webhook-5cdb4c6879-kn7lb                  1/1     Running   0          10s

$ kubectl --context kind-knative get pods -n kourier-system
NAME                                      READY   STATUS    RESTARTS   AGE
3scale-kourier-gateway-6cd8b569b4-d7xjd   1/1     Running   0          19s
```

> 这几行是一路按 9.1 做过"缩容 → 串行预拉 → 扩容"
> 之后的现场,所以 `controller` / `webhook` 的 AGE 只有 10s,而 `activator` 是 13h。
> 一次装完的正常场景下,几个 pod 的 AGE 会差不多。

`kourier` 那个 Service 会一直是 `<pending>`,这是**预期行为**,不用管:

```console
$ kubectl --context kind-knative get svc -n kourier-system
NAME               TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)                      AGE
kourier            LoadBalancer   10.96.84.113   <pending>     80:31655/TCP,443:31378/TCP   13h
kourier-internal   ClusterIP      10.96.7.79     <none>        80/TCP,443/TCP               13h
```

> 镜像拉取这一步是本实验最慢的环节,见「九、排障与已知问题」。

## 六、部署实验服务与集群内客户端

服务端用官方的 `helloworld-go` 样例,客户端就是一个常驻的 `curl` pod,
**两者放在同一个命名空间** `demo` 里——这就是"服务和发请求的服务放在一块"。

```sh
kubectl --context kind-knative create namespace demo

cat <<'EOF' | kubectl --context kind-knative apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: helloworld-go
  namespace: demo
spec:
  template:
    metadata:
      annotations:
        # 默认 stable-window 是 60s,缩容要等一分钟才看得见。
        # 调成 20s 让 1→0 更跟手(仅用于实验,生产别这么设)。
        autoscaling.knative.dev/window: "20s"
    spec:
      containers:
        - image: ghcr.io/knative/helloworld-go:latest
          env:
            - name: TARGET
              value: "Knative on kind"
EOF
```

```console
$ kubectl --context kind-knative get ksvc -n demo
NAME            URL                                           LATESTCREATED         LATESTREADY           READY   REASON
helloworld-go   http://helloworld-go.demo.svc.cluster.local   helloworld-go-00001   helloworld-go-00001   True
```

**URL 就是 `svc.cluster.local` 结尾,`READY=True`。** 不需要任何 DNS 配置。

再起客户端:

```sh
cat <<'EOF' | kubectl --context kind-knative apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: http-client
  namespace: demo
spec:
  containers:
    - name: curl
      image: curlimages/curl:latest
      command: ["sleep", "infinity"]
EOF
```

> Knative 会给每个 revision pod 注入一个 **queue-proxy** sidecar,所以
> revision pod 是 `2/2`,`kubectl get pods` 里看到两个容器:
> `user-container` + `queue-proxy`。它的镜像
> `gcr.io/knative-releases/knative.dev/serving/cmd/queue@sha256:...` **也要能拉到**,
> 预拉镜像时别漏——真正的 digest 在「9.2 需要预拉的镜像清单」里给出。

## 七、观测 activator 的 scale 动作

### 7.1 第一个请求(revision 还热着)

```console
$ kubectl --context kind-knative exec -n demo http-client -- \
    curl -s -w "\n[HTTP %{http_code}]\n" http://helloworld-go.demo.svc.cluster.local
Hello Knative on kind!

[HTTP 200]
```

### 7.2 先让副本缩到 0

默认 `min-scale=0`,空闲 `stable-window`(这里设的 20s)之后就自动缩容。
`kubectl get pods -n demo -w` 能直接看到 pod 消失;想同时看到副本数的变化,
用一个每 15s 打一次状态的小循环:

```sh
while true; do
  echo "pods: $(kubectl --context kind-knative get pods -n demo --no-headers \
        | awk '{print $1"="$3}' | tr '\n' ' ')"
  echo "PA  : $(kubectl --context kind-knative get podautoscaler -n demo --no-headers \
        | awk '{print "desired="$2" actual="$3}')"
  sleep 15
done
```

输出(只保留状态发生变化的那几拍,`PA` 是 PodAutoscaler):

```console
pods: [helloworld-go-00001-deployment-679475546c-7njvn=Running http-client=Running] PA: [desired=1 actual=1]
pods: [helloworld-go-00001-deployment-679475546c-7njvn=Terminating http-client=Running] PA: [desired=0 actual=0]
pods: [http-client=Running] PA: [desired=0 actual=0]
```

三拍的间隔分别是 15s / 30s / 60s —— 也就是第 30s 左右开始终止,第 60s 左右
`demo` 里只剩 `http-client`,业务副本归零。

此时 `-private` Service 的 endpoints 也变空了:

```console
$ kubectl --context kind-knative get endpointslice -n demo \
    -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .endpoints[*]}{.addresses[0]}{" "}{end}{"\n"}{end}'
helloworld-go-00001-25qxh -> 10.244.0.5            # activator 自己
helloworld-go-00001-private-gb5xr ->                # 空:没有后端了
```

`10.244.0.5` 就是 activator pod:

```console
$ kubectl --context kind-knative get pods -n knative-serving -l app=activator -o wide
NAME                         READY   STATUS    RESTARTS   AGE   IP           NODE
activator-56d698c974-w7564   1/1     Running   0          13h   10.244.0.5   knative-control-plane
```

### 7.3 冷启动 0 → 1

副本归零之后,再从集群里发一次请求。这个请求会先被 activator 接住挂起来,
等 revision pod 起来再转发过去:

```console
$ kubectl --context kind-knative exec -n demo http-client -- \
    curl -s -w "\n[HTTP %{http_code} total=%{time_total}s]\n" http://helloworld-go.demo.svc.cluster.local
Hello Knative on kind!

[HTTP 200 total=0.616595s]
```

**616 ms** —— 这就是从 0 拉起来的全部代价,请求一次都没丢。
紧接着看 pod,revision 已经回来了(注意 pod 是新的,IP 也变了):

```console
$ kubectl --context kind-knative get pods -n demo
NAME                                              READY   STATUS    RESTARTS   AGE
helloworld-go-00001-deployment-679475546c-6w88g   2/2     Running   0          1s
http-client                                       1/1     Running   0          6m5s

$ kubectl --context kind-knative get endpointslice -n demo \
    -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{range .endpoints[*]}{.addresses[0]}{" "}{end}{"\n"}{end}'
helloworld-go-00001-25qxh -> 10.244.0.5
helloworld-go-00001-private-gb5xr -> 10.244.0.17
```

### 7.4 看 activator 自己在说什么

activator 的日志把整件事说得很直白——`capacity` 从 0 变成"无上限(2147483647)",
就是因为有后端起来了:

```console
$ kubectl --context kind-knative logs -n knative-serving -l app=activator --tail=12
```

缩容到 0 之后(容量归零):

```json
{"logger":"activator","caller":"net/throttler.go:336","message":"Updating Revision Throttler with: clusterIP = <nil>, trackers = 0, backends = 0","knative.dev/key":"demo/helloworld-go-00001"}
{"logger":"activator","caller":"net/throttler.go:328","message":"Set capacity to 0 (backends: 0, index: 0/1)","knative.dev/key":"demo/helloworld-go-00001"}
```

冷启动那一刻(容量放开):

```json
{"logger":"activator","caller":"net/throttler.go:336","message":"Updating Revision Throttler with: clusterIP = <nil>, trackers = 1, backends = 1","knative.dev/key":"demo/helloworld-go-00001"}
{"logger":"activator","caller":"net/throttler.go:328","message":"Set capacity to 2147483647 (backends: 1, index: 0/1)","knative.dev/key":"demo/helloworld-go-00001"}
```

> 上面每行都是从原始日志里摘出的关键字段(`severity`/`timestamp`/`commit`/
> `knative.dev/controller` 等已省略),不是完整原文。

`trackers` 是挂起的请求数,`backends` 是可用后端数。想看得更细可以用
`kubectl logs -n knative-serving -l app=activator -f`。

### 7.5 完整闭环

同一个 `kubectl exec` 里隔 45s 发一次,就能看到 `0 → 1 → 0 → 1` 反复:

```console
$ for i in 1 2 3; do
    kubectl --context kind-knative exec -n demo http-client -- \
      curl -s -o /dev/null -w "req$i: HTTP %{http_code} in %{time_total}s\n" \
      http://helloworld-go.demo.svc.cluster.local
    sleep 45
  done
req1: HTTP 200 in 0.567255s
req2: HTTP 200 in 0.955507s
req3: HTTP 200 in 0.934993s
```

都是 200,没有一次丢请求。req2/req3 比 req1 慢,是因为 45s 的间隔没能让上一个
revision pod 完全退干净(缩容窗口 20s + pod 终止时间),新 pod 和正在
`Terminating` 的旧 pod 有一小段重叠:

```console
$ kubectl --context kind-knative get pods -n demo
NAME                                              READY   STATUS        RESTARTS   AGE
helloworld-go-00001-deployment-679475546c-8m7t4   2/2     Running       0          1s
helloworld-go-00001-deployment-679475546c-n6krf   2/2     Terminating   0          47s
http-client                                       1/1     Running       0          11m
```

想看到干净的"每次都是冷启动",把间隔拉到 `sleep 60` 以上。

## 八、清理

```sh
kubectl --context kind-knative delete namespace demo
kind delete cluster --name knative
```

`kind delete cluster` 会连节点容器一起删掉。colima 里的 dockerd 代理 drop-in
和 `kubernetes/kind/` 里的修复文件都可以留着,下次建集群直接复用。

## 九、排障与已知问题

### 9.1 gcr.io 极慢,而且波动巨大

Knative 的镜像几乎都在 `gcr.io/knative-releases/`。本机经代理访问 gcr.io 实测速率
在 **3 KB/s ~ 264 KB/s** 之间剧烈波动,单个 21.9 MB 的 controller 镜像拉过 **1 小时 53 分**。

**并发拉取会互相堵死**:四个镜像并行拉的时候,90 多分钟一个都没完成;
改成串行之后每个都能拉到。可用做法是先把要拉镜像的工作负载缩到 0
(避免 kubelet 插进来并发拉),串行预拉完再放回去:

```sh
# 1. 让 kubelet 别再抢带宽
kubectl --context kind-knative scale deploy -n knative-serving \
  controller webhook net-kourier-controller --replicas=0
kubectl --context kind-knative scale deploy -n kourier-system \
  3scale-kourier-gateway --replicas=0

# 2. 把 9.2 的清单落到文件,然后逐个串行拉(一次只跑一个,别并行)
kubectl --context kind-knative get deploy -A \
  -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | grep -E "knative-releases|envoyproxy|helloworld|curlimages" > /tmp/images.txt
while IFS= read -r img; do
  docker exec knative-control-plane crictl pull "$img"
done < /tmp/images.txt

# 3. 放回去
kubectl --context kind-knative scale deploy -n knative-serving \
  controller webhook net-kourier-controller --replicas=1
kubectl --context kind-knative scale deploy -n kourier-system \
  3scale-kourier-gateway --replicas=1
```

代理抖动导致的失败重试即可——docker/containerd 会复用已下载完的 layer,每次重试都有进度。

### 9.2 需要预拉的镜像清单

不用手抄,直接从集群里生成。注意 **queue-proxy 不在任何 Deployment 里**——它是控制器在
创建 revision 时注入的,镜像地址放在 `config-deployment` 的 `queue-sidecar-image`:

```sh
kubectl --context kind-knative get deploy -A \
  -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u

kubectl --context kind-knative get configmap config-deployment -n knative-serving \
  -o jsonpath='{.data.queue-sidecar-image}{"\n"}'
```

跑出来是这样(`knative-v1.23.0` 下的实测值;`local-path-provisioner` 和 `coredns` 是 kind
自带的,不用管):

```console
docker.io/envoyproxy/envoy:v1.37-latest
gcr.io/knative-releases/knative.dev/net-kourier/cmd/kourier@sha256:eedfe3938f1efa93230863099f96400a0567909d383a585021f8727fa3a6cf0b
gcr.io/knative-releases/knative.dev/serving/cmd/activator@sha256:e5ab46f3b73fa2e3898fe47f6a3a0c2bd765596f4fb36ceb4c28c35d0a74b2e5
gcr.io/knative-releases/knative.dev/serving/cmd/autoscaler@sha256:879da127b23db65d862cafa6b23fb987381d0e44150f0027d44e1f5aee83bde2
gcr.io/knative-releases/knative.dev/serving/cmd/controller@sha256:ca5062ece0329d002a81940cf4268d7898866434d70049bb93f27d3a786d3292
gcr.io/knative-releases/knative.dev/serving/cmd/queue@sha256:a3cc71ce80dbc6df8781f15eac2cf3531a4c9815271799afd8776bef9e6aeaf2
gcr.io/knative-releases/knative.dev/serving/cmd/webhook@sha256:3846e9a416665c5b9ec2e4de246cfcb5c4ab0d01ba19348aa008caf30144b650
```

再加上 demo 自己的两个(不预拉也能起控制面,只是 demo 跑不起来):

```console
ghcr.io/knative/helloworld-go:latest    # 实验服务
curlimages/curl:latest                  # 实验客户端
```

### 9.3 `kind load docker-image` 在 containerd 镜像存储下会报错

colima 这台机器的 docker 用的是 **containerd 镜像存储**
(`docker info` 里 `Storage Driver: overlayfs` + `driver-type: io.containerd.snapshotter.v1`)。
这种模式下 `kind load docker-image` 会因为多平台索引导出不全而失败:

```
Command Output: ctr: content digest sha256:c678085...: not found
```

替代做法是自己 save + import,这条路实测可用:

```sh
docker save docker.io/envoyproxy/envoy:v1.37-latest \
  | docker exec -i knative-control-plane ctr -n k8s.io images import -
```

如果本机拉不动 Docker Hub 上的镜像(如 envoy),可以走国内镜像站拉下来再改 tag:

```sh
docker pull --platform linux/arm64 docker.m.daocloud.io/envoyproxy/envoy:v1.37-latest
docker tag docker.m.daocloud.io/envoyproxy/envoy:v1.37-latest \
           docker.io/envoyproxy/envoy:v1.37-latest
```

### 9.4 节点注册不上:`mark-control-plane: nodes "..." not found`

`kubeadm init` 走到 `mark-control-plane` 阶段失败的根因在 **kubelet**。
进节点看日志:

```sh
docker exec knative-control-plane journalctl -u kubelet --no-pager -n 50
```

典型断句 `proxyconnect tcp: dial tcp: lookup <某个域名> on 192.168.5.2:53: no such host`,
两个原因都对应 3.3 里那份 `kind-proxy.conf`:

- 代理地址写成了占位符(如 `__HOST_IP__`)或节点内不可达的 `127.0.0.1`
- `NO_PROXY` 漏了 `172.18.0.0/16`,导致连 API server 也走代理

### 9.5 版本对应关系

Knative 官方只支持最近两个版本,且对 k8s 有下限要求。v1.23 的发布说明里写明
**最低 k8s 1.34**(即本文实测的这一版);换版本前先去 release notes 确认下限:

| Knative Serving | 最低 k8s | 说明 |
|---|---|---|
| v1.23 | 1.34 | 本文实测版本 |

kind v0.32.0 发布了 `kindest/node` 的 v1.33 / v1.34 / v1.35 / v1.36 镜像,
所以本次用 v1.34.8 正好卡在 v1.23 的下限上。

## 相关

- [`kubernetes/kind/`](../kubernetes/kind/) —— kind 集群配置与节点内代理修复文件
- [Knative Serving + Istio:把网络层换成 Gateway API,数据面用 ambient](Istio-GatewayAPI与Ambient.md) —— 同样是 kind 上的实测,换掉网络层与数据面的那一套
- [Knative Serving 安装文档](https://knative.dev/docs/install/yaml-install/serving/install-serving-with-yaml/)
- [net-kourier](https://github.com/knative-extensions/net-kourier)
- [Private Services(cluster-local 默认域名)](https://knative.dev/docs/serving/services/private-services/)
- [KPA 的 stable-window](https://knative.dev/docs/serving/autoscaling/kpa-specific/)
