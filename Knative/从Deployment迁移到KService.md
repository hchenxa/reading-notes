# 从 Deployment(+HPA) 迁移到 Knative Service

> 实测环境:kind 上的 Knative Serving v1.23.0 + net-kourier
> **本文的每一步、每条报错都是在本机真跑出来的** —— 包括那些"不报错但行为变了"的地方。
>
> **结论先行:Knative 里没有"把 Deployment 原地改造成 KService"这回事。**
> 你交出去的是 **Deployment + Service + HPA** 三件套,拿回来的是一棵由 KService 管理的
> 对象树(拆解见[对象模型](对象模型.md))。所以迁移的动作就是两步:
> **写一个 KService,然后删掉那三件套。**

## 一、迁移前后对照

迁移前——一个很典型的应用:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: myapp, namespace: migrate }
spec:
  replicas: 2
  selector: { matchLabels: { app: myapp } }
  template:
    metadata: { labels: { app: myapp } }
    spec:
      containers:
        - name: myapp
          image: ghcr.io/knative/helloworld-go:latest
          env: [{ name: TARGET, value: "legacy myapp" }]
          ports: [{ containerPort: 8080 }]
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 128Mi }
          readinessProbe: { httpGet: { path: /, port: 8080 }, initialDelaySeconds: 2 }
---
apiVersion: v1
kind: Service
metadata: { name: myapp, namespace: migrate }
spec:
  selector: { app: myapp }
  ports: [{ name: http, port: 80, targetPort: 8080 }]
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: myapp, namespace: migrate }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: myapp }
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
```

迁移后——只剩一个对象,伸缩策略变成注解:

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: myapp            # ← 名字很关键,见 3.3
  namespace: migrate
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/min-scale: "2"      # ← HPA 的 minReplicas
        autoscaling.knative.dev/max-scale: "10"     # ← HPA 的 maxReplicas
    spec:
      containers:
        - image: ghcr.io/knative/helloworld-go:latest
          env: [{ name: TARGET, value: "migrated myapp" }]
          resources:
            requests: { cpu: 100m, memory: 64Mi }
            limits:   { cpu: 500m, memory: 128Mi }
```

## 二、字段映射表

| 你在 Deployment/Service/HPA 里写的 | 迁到 KService 之后 |
|---|---|
| `containers[].image` / `env` / `resources` / `volumeMounts` | **原样透传**。实测 `resources.requests/limits` 完整落到了 `user-container` 上 |
| `containers[].ports[].containerPort` | **可以省**——单容器时 Knative 自动补 `8080`(实测生成的容器是 `{containerPort: 8080, name: user-port}`) |
| `containers[].ports[0].hostPort` | ❌ 被拒:`unknown field "...ports[0].hostPort"` |
| **多个端口**(跨所有容器) | ❌ 被拒:`Only a single port is allowed across all containers` |
| **`spec.replicas`** | ❌ 被拒:`unknown field "spec.template.spec.replicas"`——副本数归 KPA 管 |
| `spec.strategy`(滚动更新策略) | 没有对应物——由 Revision 的创建与流量切分取代 |
| `spec.selector` | 没有对应物——由 Knative 自己打标签(`serving.knative.dev/revisionUID`) |
| `spec.template.metadata.labels` / `annotations` | **原样保留**,而且这是唯一能传到 pod 的地方(见[对象模型](对象模型.md) 第八节) |
| Deployment **自身**的 `metadata.labels` / `annotations` | 放到 KService 的 metadata 下 —— 但那样**只到 Configuration / Route**,到不了 pod |
| `containers[].readinessProbe` | ⚠️ **静默丢弃,不报错**(见第五节) |
| `containers[].livenessProbe` | 透传,有效 |
| `Service.spec.selector` / `ports` | 自动生成(见[对象模型](对象模型.md) 4.4/4.5),**但名字会被占用** |
| `Service.spec.clusterIP` / `sessionAffinity` | 没有对应物 |
| **多容器**(sidecar) | ✅ 允许,但只有一个能声明端口(见第五节) |
| HPA `minReplicas` | `autoscaling.knative.dev/min-scale` |
| HPA `maxReplicas` | `autoscaling.knative.dev/max-scale` |
| HPA 的**指标**(cpu/memory utilization) | ❌ **没有对应物**——KPA 只认 `concurrency` / `rps`,见第四节 |

## 三、实测:一遍走完

### 3.1 迁移前:HPA 其实是坏的

```console
$ kubectl get hpa myapp -n migrate
NAME    REFERENCE          TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
myapp   Deployment/myapp   cpu: <unknown>/70%   2         10        0          9s
```

`TARGETS` 是 `<unknown>` —— 因为 kind 里**没有 metrics-server**,HPA 拿不到 CPU 指标,
这个 HPA 从建起来那天就没生效过。(这不是 kind 特有的问题:任何装 HPA 的集群都得额外
提供 metrics 来源。)

**而 Knative 不需要这个**:queue-proxy 自己就是指标源,它把并发数报给 autoscaler。
下面迁完之后 `DESIREDSCALE/ACTUALSCALE` 立刻就有数了。

### 3.2 写 KService

就是第一章里那段。**先别删旧的**——接下来会撞车。

### 3.3 坑一:KService 的名字会撞上已有的 Service

应用 KService 之后:

```console
$ kubectl apply -f myapp-ksvc.yaml
service.serving.knative.dev/myapp created

$ kubectl get ksvc myapp -n migrate
NAME    URL                                  LATESTCREATED   LATESTREADY   READY   REASON
myapp   http://myapp.migrate.svc.cluster.local   myapp-00001                False   NotOwned

$ kubectl get route myapp -n migrate -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
IngressReady=False  NotOwned: There is an existing placeholder Service "myapp" that we do not own.
Ready=False         NotOwned: There is an existing placeholder Service "myapp" that we do not own.
```

原因在[对象模型](对象模型.md) 4.5 节:Route 要创建一个**和 KService 同名**的 Service 作为
入口。你的命名空间里已经有一个 `myapp` 了,Knative 拒绝接管一个不是它创建的对象。

**这就是迁移不能"就地生效"、必须删旧对象的根本原因。** 两个办法:

- 删掉同名 Service,让 Knative 建(推荐,见下);
- 或者给 KService 换个名字(但那样 URL 也变了)。

### 3.4 删掉被取代的三件套

```console
$ kubectl delete hpa myapp -n migrate
horizontalpodautoscaler.autoscaling "myapp" deleted
$ kubectl delete deploy myapp -n migrate
deployment.apps "myapp" deleted
$ kubectl delete svc myapp -n migrate
service "myapp" deleted
```

> 删 Deployment 会连带删掉它的 pod。想平滑的话这个顺序要配合流量切换做——本地实验里
> 直接删就行,真正的生产迁移应该先把 KService 用**另一个名字**跑起来,验证无误再切流量、
> 删旧对象(这也是 Knative 灰度能力该用的地方)。

### 3.5 验证

```console
$ kubectl get ksvc myapp -n migrate
NAME    URL                                  LATESTCREATED   LATESTREADY    READY
myapp   http://myapp.migrate.svc.cluster.local  myapp-00001   myapp-00001    True      ← 约 25s 后

$ kubectl run tmp-curl --rm -i --restart=Never -n migrate --image=curlimages/curl -- \
    curl -s -w " [HTTP %{http_code}]\n" http://myapp.migrate.svc.cluster.local
Hello migrated myapp! [HTTP 200]
```

**HPA 的意图完整保留下来了**,表现在 PodAutoscaler 上:

```console
$ kubectl get pa myapp-00001 -n migrate
NAME          DESIREDSCALE   ACTUALSCALE   READY   REASON
myapp-00001   2              2             True

$ kubectl get pa myapp-00001 -n migrate -o json \
    | jq -r '.metadata.annotations | to_entries[] | select(.key|startswith("autoscaling")) | "\(.key) = \(.value)"'
autoscaling.knative.dev/class = kpa.autoscaling.knative.dev
autoscaling.knative.dev/max-scale = 10
autoscaling.knative.dev/metric = concurrency
autoscaling.knative.dev/min-scale = 2
```

`DESIREDSCALE=2` 就是原来的 `minReplicas: 2`。pod 也从"你的一个容器"变成了
`user-container + queue-proxy`。

## 四、HPA → KPA:名字能对上,语义对不上

这是迁移里**最容易想当然**的地方。

**能对上的**:`minReplicas` / `maxReplicas` → `min-scale` / `max-scale`。

**对不上的**:指标。HPA 大多按 CPU,KPA 默认按**并发请求数**:

```
autoscaling.knative.dev/metric = concurrency     ← 默认值
```

而且这不是"换个名字"的事——**KPA 根本不支持 CPU / memory**:

```console
$ # 想照搬 HPA 的 cpu 70%
$ kubectl apply -f - <<'EOF'
...
        autoscaling.knative.dev/metric: cpu
        autoscaling.knative.dev/target: "70"
EOF
Error from server (BadRequest): admission webhook "validation.webhook.serving.knative.dev"
  denied the request: validation failed: invalid value: cpu:
  spec.template.metadata.annotations.autoscaling.knative.dev/metric
```

`memory` 同样被拒。**合法取值只有 `concurrency` 和 `rps`**。

### 那你原来按 CPU 扩缩的服务怎么办

三条路,按推荐程度排:

1. **换算成并发**(推荐)。CPU 利用率高通常说明请求在排队——那正是并发要解决的。
   设 `autoscaling.knative.dev/target: "<每个副本的目标并发数>"`,先在
   `concurrency`(默认)下跑一段,看 `queue-proxy` 报出来的实际并发再定值。
   附带好处:这样能**缩到 0**,而 CPU 指标永远做不到(只有一个请求都没有才没 CPU,
   但 HPA 观察不到"没有请求"这件事)。
2. **真的必须按 CPU**,用 Knative 自带的 HPA class:
   ```yaml
   autoscaling.knative.dev/class: hpa.autoscaling.knative.dev
   autoscaling.knative.dev/metric: cpu
   autoscaling.knative.dev/target: "70"
   ```
   这个注解组合**能通过校验**(实测),但要注意两个代价:
   - **需要额外装 `serving-hpa.yaml`**。没装的话 —— 实测 —— KService 创建成功但
     Revision 会一直卡在 `READY=Unknown / Deploying`,不会有任何指向真正原因的报错。
   - **HPA class 不能缩到 0**(HPA 的 `minReplicas` 最小就是 1),Knative 最值钱的那个
     特性就没了。
3. 维持原样别迁。如果这个服务本来就常驻、也不在乎缩容,那 KService 的主要收益不在你身上。

## 五、会静默改变行为、或直接报错的东西(全部实测)

**⚠️ 静默丢弃 —— 不报错,但行为变了**

```console
$ # KService 里写了 readinessProbe: { httpGet: { path: /, port: 8080 }, periodSeconds: 5 }
$ kubectl get deploy t-probe2-00001-deployment -n migrate -o json \
    | jq '.spec.template.spec.containers[] | {name, readinessProbe, livenessProbe}'
{ "name": "a",          "readinessProbe": null, "livenessProbe": {…} }   ← readiness 没了
{ "name": "queue-proxy", "readinessProbe": {…K-Network-Probe…} }          ← 就绪探针在它身上
```

**`readinessProbe` 被直接丢掉了。** 就绪判定由 queue-proxy 负责(它探自己的 8012 端口),
所以你的探针没有意义 —— 但它**不会告诉你**,只是消失。`livenessProbe` 则原样保留、有效。

**⚠️ 客户端写死的地址会失效 —— 至少要写成 `<name>.<ns>`**

入口 Service 的名字确实等于 KService 名字(同名即可),但**裸短名不在网关的 Host 白名单里**:
同命名空间里 `curl http://myapp` 会拿到网关回的 `404: server: envoy`(不是 DNS 错误,
连接是通的),只有 `http://myapp.migrate` / `…migrate.svc` / 完整 FQDN 才是 200;
端口也只认入口那层的 80(`:8080` 直接连不上)。也就是说**客户端要改地址(改配置,不是改代码)**。
详见 [对象模型 9.1](对象模型.md)。

**❌ 直接报错 —— 好在这类至少会说话**

| 你写的 | 报错 |
|---|---|
| `spec.template.spec.replicas: 3` | `unknown field "spec.template.spec.replicas"` |
| `ports[0].hostPort: 8080` | `unknown field "...ports[0].hostPort"` |
| 两个容器各带一个端口 | `more than one container port is set ... Only a single port is allowed across all containers` |
| 多容器且**都不写** `ports` | `missing field(s): spec.template.spec.containers[*].ports` |
| `metric: cpu` / `memory` | `invalid value: cpu: ...autoscaling.knative.dev/metric` |

**✅ 允许,但要理解语义**

**多容器(sidecar)是支持的**,限制是"跨所有容器只能有一个端口":

```console
$ kubectl get deploy t-multi-00001-deployment -n migrate \
    -o jsonpath='{range .spec.template.spec.containers[*]}  - {.name}  ports={.ports}{"\n"}{end}'
  - app         ports=[{"containerPort":8080,"name":"user-port","protocol":"TCP"}]
  - sidecar     ports=                     ← 没有端口,它只是搭车的
  - queue-proxy ports=[{9090 http-autometric},{9091 http-usermetric},{8012 queue-port},{8112 https-port}]
```

要迁的 Deployment 里如果有 sidecar(日志收集、服务网格代理之类),把端口留给主容器即可。
注意网格 sidecar 通常没必要——用 ambient 那种`ztunnel` 就不进 pod(见 [Istio 篇](Istio-GatewayAPI与Ambient.md))。

## 六、Service 类型:原来那个 LoadBalancer / NodePort 怎么办

### Knative 生成的 Service,类型是写死的

迁过来之后你不再创建 Service。控制器建的那三个,类型固定:

```console
$ kubectl get svc -n demo -o custom-columns='NAME:.metadata.name,TYPE:.spec.type,TARGET:.spec.ports[*].targetPort,SELECTOR:.spec.selector'
NAME                          TYPE           TARGET                                      SELECTOR
helloworld-go                 ExternalName   80                                          <none>          ← 入口,指向网关
helloworld-go-00002           ClusterIP      8012,8112                                   <none>          ← 端点由 SKS 写
helloworld-go-00002-private   ClusterIP      8012,8112,http-autometric,http-usermetric   map[serving.knative.dev/revisionUID:…]
```

**没有一个是 LoadBalancer**,而且你改不了 —— 它们由控制器创建并持续调和。

### Knative 里的 "LoadBalancer" 是共享的,不是每个服务一个

整个集群只有一个:

```console
$ kubectl get svc -A --field-selector spec.type=LoadBalancer
NAMESPACE        NAME      TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
kourier-system   kourier   LoadBalancer   10.96.84.113   <pending>     80:31655/TCP,443:31378/TCP
```

所有 KService 共用这一个网关,**靠 Host 区分**(`helloworld-go.demo.svc.cluster.local` 就是那个 host,
不用你自己写路由)。所以"每个服务一个专属外部 IP"这个模型在 KService 这一层没有了。

### 自己挂一个 NodePort / LoadBalancer 指向 pod:能通,但会打断缩容

revision pod 上有现成的 label 可以选:

```console
$ kubectl get pod <revision-pod> -n demo -o json | jq -r '.metadata.labels | keys[]'
app
pod-template-hash
serving.knative.dev/configuration
serving.knative.dev/revision          ← 用它做 selector
serving.knative.dev/revisionUID
serving.knative.dev/service
```

于是你可以自己挂一个:

```yaml
apiVersion: v1
kind: Service
metadata: { name: myapp-nodeport, namespace: demo }
spec:
  type: NodePort
  selector: { serving.knative.dev/revision: helloworld-go-00002 }
  ports: [{ name: http, port: 80, targetPort: 8012 }]
```

**pod 在的时候它能通**(targetPort 写 `8080` 打用户容器、写 `8012` 打 queue-proxy,实测都可以)。
但 **revision 缩到 0 之后它就死了**,而且死得很安静:

```console
$ # revision 缩到 0 之后
$ kubectl get endpointslice -n demo -l kubernetes.io/service-name=t-np \
    -o jsonpath='{.items[*].endpoints[*].addresses[0]}'
                                          ← 空,没有任何端点

$ kubectl exec -n demo http-client -- curl -s -m 10 http://t-np.demo.svc.cluster.local
command terminated with exit code 7       ← 连不上

$ # 同一时刻,走 Knative 的路径:
$ kubectl exec -n demo http-client -- curl -s -o /dev/null \
    -w '%{http_code} in %{time_total}s\n' http://helloworld-go.demo.svc.cluster.local
200 in 0.505637s                          ← activator 把它从 0 拉起来了
```

**根本原因:它绕过了 activator。** activator 就是"把请求挂住、触发扩容"的那一环,
它挂在 Knative 自己的路径上 —— `<rev>` 那个**没有 selector** 的 Service,端点由 SKS 写
(见[对象模型](对象模型.md) 4.4)。

> 还有一个更隐蔽的:**绕开 queue-proxy 的流量不被计数**。KPA 的并发数来自 queue-proxy,
> 所以直连 `:8080` 的请求它看不见 —— 可能正服务着就把副本缩了。走 `:8012` 至少计数还在,
> 但依然绕过 activator。(这条是推理:两个前提都实测过,组合起来的结果我没跑。)

### 那原来需要 LoadBalancer 的需求怎么落地

| 你原来想要 | Knative 里对应什么 |
|---|---|
| 一个固定外部 IP,按 host / path 分流 | **共享网关 + host 路由**。KService 的域名就是 host,不用自己写路由规则 |
| 每个服务一个专属 IP | KService 这一层没有。要么给每个服务单独起 Gateway(net-gateway-api / Istio 那套,见 [Istio 篇](Istio-GatewayAPI与Ambient.md)),要么接受共享 |
| 只想集群内可达 | **什么都不用做**——Knative 默认就是集群内,比原来更安全 |
| 自定义域名 | `DomainMapping`,把域名指到 KService |
| 想让 `kourier` 那个 LoadBalancer 真拿到 IP(kind 上) | 需要 LoadBalancer 实现:cloud-provider-kind 或 MetalLB |

## 七、什么时候不该迁

- **需要常驻、不能容忍冷启动**:把 `min-scale` 设成正数就能留热副本,但要接受它不再缩到 0。
- **按 CPU/内存扩缩是硬需求**:见第四节,那要付 HPA class 的代价(装组件 + 失去缩容到 0)。
- **多端口服务**:Knative 一个 Revision 只允许一个端口。多端口得拆成多个 KService。
- **依赖 `hostPort` / 固定节点端口**:直接不支持。
- **需要自定义滚动更新策略 / PodDisruptionBudget 之类**:这些是 Deployment 层的东西,
  KService 那一层不暴露。

### 具体的反例:StatefulSet 那类有状态服务

"想给一个 StatefulSet 的 DB 设 `min-scale: 3`,但没法自定义 Service" —— 这个场景
**Knative Serving 处理不了**。而且不是"差一个功能",是几条设计前提直接对不上:

| 你需要的 | Knative 的情况 | 实测证据 |
|---|---|---|
| **TCP / 自有协议** | 数据面只认 HTTP。KIngress 的规则就是 `hosts + http.paths[]`(按 HTTP 路径匹配),没有 TCP 那一支;入口链路是 网关 → activator → **queue-proxy(HTTP 反向代理)** → 你的容器 | `kubectl explain ingresses.networking.internal.knative.dev.spec.rules` |
| **多个端口**(DB + 健康检查) | 跨所有容器只允许一个端口 | ❌ `Only a single port is allowed across all containers` |
| **headless Service** | 生成的 Service 归控制器;headless 在 k8s 层面就不可能 | ❌ `spec.clusterIPs[0]: may not change once set` |
| **自定义 Service 形状** | 加 label 会留下,改 `ports` 会被控制器改回去 | 实测:label 保留;ports 改完 25s 后仍是原样 |
| **稳定的 Pod 标识**(`db-0` / `db-1`) | 没有。pod 名是 `<ksvc>-00002-deployment-<hash>-<rand>`,副本之间可互换、无序号。`min-scale: 3` 只保证"有 3 个",不保证"哪 3 个" | 见[对象模型](对象模型.md) |
| **改配置不重造实例** | 改一个字段就生成 `db-00002`,而旧的那套对象**不会被删**("每 Revision 一棵树")。对无状态服务这是秒回滚,对 DB 就是同时出现两份实例 | [对象模型](对象模型.md) 第五节 |
| **PVC / `volumeClaimTemplate`** | PVC 默认是**关的**(要先开 `kubernetes.podspec-persistent-volume-claim`);而开了也只是"能挂一个卷",上面几条一条都没解决 | ❌ `Persistent volume claim support is disabled` |

**所以这个场景就用 StatefulSet + headless Service,别用 Knative。**
Knative Serving 的定义就是"无状态、请求驱动的 HTTP 工作负载"——有状态服务要的排序、稳定标识、
有序启停,它一样都不提供。

更实际的落地方式通常是**把有状态的留在外面,只把应用侧迁进来**:DB 继续用 StatefulSet(或托管
数据库),跑 HTTP 的业务服务迁成 KService。Knative 的收益(缩到 0、Revision 灰度、不用管副本数)
本来就在无状态那一侧。

反过来说,如果这个服务是**HTTP、单端口、流量有波峰波谷**,那迁移的收益最直接:
不用管副本数、空闲不花钱、发布/回滚由 Revision 天然管住。

## 相关

- [Knative 对象模型](对象模型.md) —— 迁完之后集群里到底多了哪 10 个对象
- [Kourier 篇](Kourier.md) —— 装、观测 scale-to-zero、本机 kind 的环境坑
- [Istio 篇](Istio-GatewayAPI与Ambient.md) —— 换网络层/数据面,以及 ambient 下 sidecar 的位置
