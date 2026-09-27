# Kubernetes 学习笔记

## 目录索引

| 主题 | 说明 |
|------|------|
| [Informer](Informer/) | Informer 机制：Reflector、Delta FIFO、Indexer、事件分发 |
| [Pod 调度](PodScheduler/) | Pod 调度生命周期、调度框架、扩展点 |
| [gVisor](gVisor/) | gVisor 在 kind 集群中的启用、验证与排障 |
| [Gateway API](GatewayAPI/) | Gateway API 详解：对象模型与角色分工、GatewayClass/Gateway/HTTPRoute 等字段级用法、TLS/mTLS、版本演进、Ingress 迁移与排障 |
| [Istio](Istio/) | Istio 升级三件事：Gateway 配置清空 Bug（#59959）的根因与修复、patch label 与翻 tag 的中断差异、In-place 与 Revision 升级的使用与区别 |
