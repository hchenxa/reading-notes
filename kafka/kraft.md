## Kraft模式

- kafka不再依赖于外部框架(zookeeper)，而是能够独立运行。
- controller管理集群时，不再需要从zookeeper中先读取数据，集群性能上升。
- 由于不依赖于zookeeper, 集群扩展的时候不再收到zookeeper读写能力的限制
- contoller不再动态选举，由配置文件规定，可以自由的针对性加强controller节点的配置。
