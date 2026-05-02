## 宏观层面：跨组件的 Pod 调度生命周期

从你提交一个 Pod 的 YAML 文件，到它最终在某个节点上跑起来，源码层面的核心交互链路如下：

1. 用户提交与 API Server 接收
 
当你执行`kubectl apply -f pod.yaml`时，请求首先发送给`kube-apiserver`。API Server 会对请求进行校验，然后将这个未指定节点的 Pod 对象持久化写入到集群的数据库 etcd 中。

2. 调度器监听与入队

`kube-scheduler`内部通过 Informer 机制，持续监听（Watch）API Server 中 Pod 对象的增删改事件。当它发现有新的 Pod 被创建且 spec.nodeName 字段为空（即处于未调度状态）时，会触发回调函数，将这个 Pod 放入内部的调度队列（Scheduling Queue）中。

3. 调度决策与绑定

调度器从队列中取出这个Pod，启动核心的调度算法。它会结合本地缓存的集群节点信息（Node Cache），经过一系列复杂的过滤和打分逻辑，选出一个最合适的节点（Node）。随后，调度器通过 API Server 发起一个 Binding 请求，将该 Pod 与选定的节点进行绑定，并将绑定关系更新到 etcd 中。

4. Kubelet 接管与容器创建

目标节点上的 kubelet 同样通过 Informer 监听 API Server。当它发现有新的 Pod 被绑定到了自己所在的节点上，就会正式接管这个 Pod。Kubelet 会调用底层的容器运行时（如 containerd），依次执行创建 Pod 沙箱（Pause 容器）、拉取镜像、挂载存储卷、配置网络以及启动业务容器等操作。

## 微观层面：kube-scheduler 内部的源码执行流

如果我们把镜头拉近，深入到 kube-scheduler 的源码内部（核心逻辑位于 pkg/scheduler/ 目录下），它的单次调度周期（Scheduling Cycle）主要包含以下几个关键阶段：

1. 调度队列管理（Scheduling Queue）

调度器并不是来一个Pod就立刻处理，而是通过队列进行精细化管理。在源码 pkg/scheduler/internal/queue/ 中，主要维护了三个子队列：

- **ActiveQ**（活跃队列）：存放等待调度的 Pod，内部是一个基于优先级（Priority）的堆（Heap），确保高优先级的Pod优先被调度。
- **UnschedulableQ**（不可调度队列）：存放暂时因为资源不足等原因无法调度的 Pod。
- **BackoffQ**（退避队列）：存放调度失败、正在等待退避时间的 Pod，避免频繁无效重试。

2. 调度框架与扩展点（Scheduler Framework）

自 Kubernetes 1.15 起，调度器引入了插件化的调度框架（pkg/scheduler/framework/），将调度过程拆解为多个扩展点。一个 Pod 从出队到绑定，会依次经过以下核心扩展点：

- **PreFilter**（预过滤）：对 Pod 的信息进行预处理或做一些全局性的合法性检查。
- **Filter**（过滤 / 预选）：这是“淘汰赛”阶段。调度器会并行调用一系列 Filter 插件（如 NodeResourcesFit 检查资源是否够用、NodeAffinity 检查节点亲和性、TaintToleration 检查污点容忍度等），将不满足硬性条件的节点全部剔除。
- **PostFilter**：如果 Filter 阶段把所有节点都淘汰了（导致调度失败），会触发此扩展点。这里最典型的操作就是抢占（Preemption），即尝试驱逐一些低优先级的 Pod 来为当前 Pod 腾出资源。
- **PreScore**（预打分）：在正式打分前做一些预处理工作。
- **Score**（打分 / 优选）：这是“排位赛”阶段。调度器调用一系列 Score 插件（如 ImageLocality 优先选择已有镜像的节点、NodeResourcesBalancedAllocation 优先选择 CPU/内存使用更均衡的节点）对剩余的候选节点进行打分（0-100分），最后按权重汇总得出总分。
- **Reserve**（资源预留）：在真正绑定之前，先在调度器的缓存中“预留”该节点的资源，防止并发调度导致资源超卖。
- **Permit**（许可）：用于拦截或延迟 Pod 的绑定，常用于实现 Pod 的成组调度（Gang Scheduling）。
- **PreBind**（预绑定）：执行绑定前的收尾工作，最典型的插件是 VolumeBinding，负责完成存储卷的动态制备和挂载绑定。
- **Bind**（绑定）：将最终的调度结果（Pod 绑定到哪个 Node）通过 API Server 写入 etcd。
- **PostBind**（绑定后）：绑定成功后的清理工作，比如清理 Reserve 阶段留下的状态。

3. 假设缓存（Assume Cache）
为了提高调度吞吐量，调度器在 Bind 阶段并不是同步等待 etcd 写入成功。它在源码中采用了 Assume（假设）机制：在发出绑定请求的同时，直接在本地缓存（Scheduler Cache）中假设该 Pod 已经占用了目标节点的资源。这样，下一个 Pod 的调度就可以立刻基于最新的（假设的）资源状态进行计算，而不用等待 etcd 的异步写入完成。

## 总结一下：

从源码层面看，Pod 的调度生命周期就是 API Server 作为中枢，调度器通过 Informer 监听、利用本地缓存和插件化框架进行高效的过滤与打分，最终通过 Binding 接口完成节点分配；随后 Kubelet 监听到变化，调用容器运行时完成真正的容器拉起。这套机制保证了 Kubernetes 集群在面对海量 Pod 时，依然能保持高效、可扩展的调度能力。