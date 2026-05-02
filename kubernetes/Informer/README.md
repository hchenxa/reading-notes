Kubernetes 的 Informer 机制是 Kubernetes 控制平面的核心组件之一，也是所有 Controller（控制器）能够感知集群状态变化的“眼睛”和“耳朵”。

简单来说，Informer 就是一个带有本地缓存和索引机制的客户端。它的主要作用是：

1. 减轻 API Server 压力：通过维护一份本地缓存，让业务逻辑直接查本地内存，而不是频繁去请求 API Server。

2. 实时感知变化：通过监听（Watch）机制，实时获取集群中资源（如 Pod、Deployment）的增删改事件。

## 🏗️ Informer 的核心组件架构

Informer 并不是一个单一的结构，而是由多个组件精密配合完成的。我们可以把它拆解为以下几个核心部分：

- **Reflector**（反射器）：负责“跑腿”的侦察兵。它通过 Kubernetes 的 List 和 Watch 机制与 API Server 建立连接。
- **Delta FIFO Queue**（增量队列）：一个先进先出的队列，用来存放 Reflector 抓取回来的资源对象以及对应的事件类型（如 Added, Updated, Deleted）。
- **Indexer**（本地缓存与索引器）：Informer 的本地内存数据库，不仅存储了资源对象的全量数据，还支持按命名空间、标签等多种方式建立索引，方便快速查询。
- **Controller**（内部控制器）：负责从 Delta FIFO Queue 中不断取出事件，更新 Indexer 本地缓存，并触发相应的事件处理器。
- **Processor & Listener**（分发器与监听器）：负责将事件分发给注册了该资源变化的各种业务控制器（比如 Deployment Controller、Service Controller）。

## ⚙️ Informer 的工作流程

Informer 的工作流程可以形象地分为“全量拉取”、“增量监听”和“事件分发”三个阶段：

1. 启动与全量同步 (List)

当 Informer 启动时，内部的 Reflector 会首先调用 API Server 的 List 接口，把当前集群中该类型的所有资源对象一次性全部拉取下来。这些数据会被包装成 Sync 或 Replaced 类型的事件，放入 Delta FIFO Queue 中。

2. 持续监听与增量更新 (Watch)

全量拉取完成后，Reflector 会立刻发起 Watch 请求，保持一个长连接。一旦集群中的资源发生变化（比如创建了一个新 Pod），API Server 就会通过这个连接把变更事件（Added, Updated, Deleted）实时推送给 Reflector。Reflector 收到后，将这些增量事件放入 Delta FIFO Queue。

3. 消费事件与更新缓存

Informer 内部的 Controller 会不断从 Delta FIFO Queue 中 Pop（取出）事件：
更新本地缓存：根据事件类型，将对象增删改到 Indexer（本地内存）中。
触发回调：通知 Processor，告诉它“有个资源变了”。

4. 事件分发

Processor 会遍历所有注册了该资源监听器的业务 Controller（通过 AddEventHandler 注册的 OnAdd, OnUpdate, OnDelete 回调函数），把变更事件分发给它们。业务 Controller 收到事件后，通常会把资源对象的 Key 放入自己的工作队列（WorkQueue），然后由自己的控制循环去执行具体的调谐（Reconcile）逻辑。

## 🏭 SharedInformerFactory（共享机制）

在实际开发或 K8s 源码中，你经常会看到 SharedInformerFactory。这是为了解决资源浪费问题而设计的。

如果一个进程中有多个 Controller 都需要监听 Pod 的变化，如果每个 Controller 都单独起一个 Informer 去 List/Watch API Server，会造成极大的网络压力和资源浪费。

`SharedInformerFactory` 就像一个工厂，它保证了同一种资源（比如 Pod）在整个进程中只会有一个 Informer 实例在运行。这个唯一的 Informer 负责与 API Server 通信并维护一份本地缓存，然后将事件广播给所有对该资源感兴趣的 Controller。

## 💡 总结

Kubernetes Informer 机制通过 Reflector 的 List/Watch 实现了与 API Server 的高效通信，通过 Indexer 实现了本地缓存和快速检索，通过 Processor 实现了事件的广播分发。它完美地解决了分布式系统中“状态同步”与“事件驱动”的难题，是 K8s 能够高效、稳定运行的基石。

