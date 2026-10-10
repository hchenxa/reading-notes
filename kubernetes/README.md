# Kubernetes 学习笔记

## 目录索引

| 主题 | 说明 |
|------|------|
| [Informer](Informer/) | Informer 机制：Reflector、Delta FIFO、Indexer、事件分发 |
| [Knative Serving](Knative/) | 在 kind 上装 Knative Serving + Kourier，从集群内观测 activator 的 scale-to-zero |
| [Pod 调度](PodScheduler/) | Pod 调度生命周期、调度框架、扩展点 |
| [gVisor](gVisor/) | gVisor 在 kind 集群中的启用、验证与排障 |
| [Gateway API](GatewayAPI/) | Gateway API 详解：对象模型与角色分工、GatewayClass/Gateway/HTTPRoute 等字段级用法、TLS/mTLS、版本演进、Ingress 迁移与排障 |
