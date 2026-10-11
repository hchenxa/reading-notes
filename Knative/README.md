# Knative

> 这个目录是 Knative Serving 在本地 kind 集群上的实操记录。
> 两篇走的是**同一条主线**:装好 Serving,从集群内部发 curl,观察 activator 把 revision
> 从 0 拉到 1、再缩回 0。区别只在**网络层**和**数据面**选了什么。

## 两篇实验

| 文档 | 网络层 | Gateway 谁提供 | 数据面 |
|---|---|---|---|
| [Kourier 篇](Kourier.md) | `net-kourier` | Kourier 自带的 Envoy | 无 mesh |
| [Istio 篇](Istio-GatewayAPI与Ambient.md) | `net-gateway-api` | Istio 提供的 GatewayClass `istio` | Istio ambient(无 sidecar) |

**建议从 [Kourier 篇](Kourier.md) 开始。** 它不只是"另一种方案":安装步骤、
Scale-to-Zero 的机制(ServerlessService / activator / 冷启动)、以及**本机 kind 的全部环境坑**
(colima 资源不够、两层代理、`DOCKER_HOST` 指向 podman、gcr.io 拉取慢到病态)都在那一篇。
Istio 篇假设你已读过它的第三章,不再重复。

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
