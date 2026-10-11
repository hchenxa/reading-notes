# Knative

> 这个目录是 Knative Serving 在本地 kind 集群上的记录:**两篇动手实验** + **两篇拆解机制 / 迁移的参考**。

## 四篇文档

### 动手跑:两篇实验

同一条主线 —— 装好 Serving,从集群内部发 curl,观察 activator 把 revision 从 0 拉到 1、
再缩回 0。区别只在**网络层**和**数据面**选了什么。

| 文档 | 网络层 | Gateway 谁提供 | 数据面 |
|---|---|---|---|
| [Kourier 篇](Kourier.md) | `net-kourier` | Kourier 自带的 Envoy | 无 mesh |
| [Istio 篇](Istio-GatewayAPI与Ambient.md) | `net-gateway-api` | Istio 提供的 GatewayClass `istio` | Istio ambient(无 sidecar) |

**建议从 [Kourier 篇](Kourier.md) 开始。** 它不只是"另一种方案":安装步骤、
Scale-to-Zero 的机制(ServerlessService / activator / 冷启动)、以及**本机 kind 的全部环境坑**
(colima 资源不够、两层代理、`DOCKER_HOST` 指向 podman、gcr.io 拉取慢到病态)都在那一篇。
Istio 篇假设你已读过它的第三章,不再重复。

### 拆开看:两篇参考

| 文档 | 讲什么 |
|---|---|
| [对象模型](对象模型.md) | 写一个 KService 之后集群里多出什么:10 个对象各自归谁、Revision 的基数 / 回收 / 命名、请求路径,以及"怎么访问它 / 怎么知道请求落在哪个 Revision / 换个网络层这棵树哪里变"这些实操问答 |
| [从 Deployment(+HPA) 迁移到 KService](从Deployment迁移到KService.md) | 拿现有应用动手迁:字段映射表、**会静默改变行为**的东西(`readinessProbe` 被吞掉、客户端写死的地址失效)、Service 类型怎么办,以及什么时候不该迁(有状态服务) |

推荐顺序:**Kourier 篇 → 对象模型 → 迁移篇**;要换 Istio 那套再看 Istio 篇。

## 一个共同的前提:Knative 必须有网络层

Knative Serving **自己不做数据面**,它只定义 KIngress 规范,路由必须由一个网络层实现来提供。
可选的就四个,而 `config-network` 里 `ingress-class` 的**默认值就是 istio**:

| 实现 | `ingress-class` 取值 |
|---|---|
| net-istio | `istio.ingress.networking.knative.dev`(**默认值**) |
| net-kourier | `kourier.ingress.networking.knative.dev` |
| net-contour | `contour.ingress.networking.knative.dev` |
| net-gateway-api | `gateway-api.ingress.networking.knative.dev` |

不装任何实现,`Ingress` 资源没人处理,KService 会永远 `NotReady`——**没有"不装网络层"这个选项**。
所以"不用 Istio"的正确做法是换一个别家的实现,而不是不装。

### 这个值配在哪、能不能按 Route 单独指定

配在 **`knative-serving` 命名空间的 `config-network`** 里 —— 安装步骤里那条 `kubectl patch` 就是它:

```console
$ kubectl get cm config-network -n knative-serving -o json | jq -r '.data["ingress-class"]'
kourier.ingress.networking.knative.dev
```

三个容易误解的点(都实测过):

- **值写的是全名** `<实现>.ingress.networking.knative.dev`,不是 `kourier` 三个字母。
- **没有 `IngressClass` 这种对象可以建。** 这个版本里 Knative 已经没有那个 CRD
  (`kubectl api-resources | grep -i ingress` 只剩 `ingresses`),它纯粹是"配置里的字符串"
  和"控制器监听哪个字符串"之间的约定。写错了**不报错**,只是没人处理:
- **可以按 Route 覆盖,但只在创建时生效。** 在 KService 自己的 metadata 上写
  `networking.knative.dev/ingress-class`(dash),它会传到 Route 并决定这条 Route 用哪个 class:

  ```console
  $ kubectl get route classtest -n migrate -o json \
      | jq -r '.status.conditions[]|select(.type=="Ready")|"\(.status) \(.reason)"'
  Unknown IngressNotConfigured     ← 指到一个没装控制器的 class,就是这个下场
  ```

  反过来,**往一个已经存在的 Route 上事后加同一注解是无效的**(dash / dot 两种写法都试过,
  KIngress 里记的还是老值,Route 照样 Ready)。因为 class 在 Route **创建时**就被解析好、
  盖在 KIngress 上了 —— 记在 KIngress 的 `networking.knative.dev/ingress.class`(这里是 dot),
  这也正是 `config-network` 里那句"对已有 Route 改 class 会 undefined behavior"的含义。

## 不管选哪个网络层,下面这些都不变

- KService 的 URL 默认就是集群内域名 `<name>.<namespace>.svc.cluster.local`(Knative ≥ v1.8)。
  不需要 DNS、不需要 LoadBalancer —— 在 kind 上也就完全绕开了 `cloud-provider-kind`
  那套要靠 sudo 前台进程维持的东西。
- 默认 `min-scale=0`,ServerlessService 处于 `Proxy` 模式,**流量全程经过 activator**。
- 空闲一个 `stable-window`(默认 60s)后缩到 0;下一个请求由 activator 先挂住、触发扩容,
  实测冷启动 **0.6 ~ 1.1 秒**。
- 业务 pod 永远是 `2/2`:`user-container` + Knative 注入的 **queue-proxy**(它的镜像不在任何
  Deployment 里,预拉镜像时容易漏)。

## 环境依赖

两个实验共用同一套 kind 基础设施,放在 [`kubernetes/kind/`](../kubernetes/kind/)——
那是 K8s 基建,所以没跟着 Knative 一起搬出来:

- `kind-config.yaml` —— 建集群时把下面那份代理 drop-in 挂进节点
- `kind-proxy.conf` —— 节点内 `containerd` / `kubelet` 的代理配置(含 `NO_PROXY` 必须覆盖的网段)

## 相关

- [`kubernetes/`](../kubernetes/) —— Kubernetes 本身的笔记(Gateway API、gVisor、调度等)
- [`Istio/`](../Istio/) —— Istio 本身的笔记(Gateway 配置清空的 bug、升级方式等),和本目录的
  Istio 篇是互补的:那边讲 Istio 自身的行为,这边讲 Istio 怎么当 Knative 的网络层
