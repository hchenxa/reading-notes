# Prow 学习笔记

> 一套按序号读的 Prow 笔记:**00 讲定位与组件架构,01 讲 plugin 机制**,
> 02 讲怎么开发和扩展,03/04 专门展开 GitHub 集成与 PR 自动化。
>
> - 版本基线:kubernetes-sigs/prow `main` @ `6dceccd02`(2026-11-26)
> - 结论来源:阅读当前仓库源码 + 官方文档;**没有在本机部署一套 Prow 实测**
> - 官方文档有漂移:涉及 plank、Life of a Prow Job、approve 页面时,以源码为准

## 一、文件索引

| 文件 | 内容 | 状态 |
|------|------|------|
| [00-概念与架构](00-概念与架构.md) | Prow 解决什么问题、组件分工、ProwJob 状态机、一次 job 的完整链路 | 未实测(源码整理) |
| [01-Plugin机制](01-Plugin机制.md) | 注册表、事件分发、plugins.yaml 合并与热加载、plugin help、external plugin 契约 | 未实测(源码整理) |
| [02-Plugin开发与扩展](02-Plugin开发与扩展.md) | 启用已有 plugin、新增内置 plugin、部署 external plugin、测试与排错 | 未实测(源码整理) |
| [03-GitHub事件与认证](03-GitHub事件与认证.md) | webhook 验签、7 类事件、PAT/GitHub App、ghproxy、限流指标 | 未实测(源码整理) |
| [04-PR自动化与仓库治理](04-PR自动化与仓库治理.md) | OWNERS/approve/lgtm、Tide 合并决策、batch、peribolos/branchprotector | 未实测(源码整理) |

**推荐顺序:00 → 01 → 02**,然后按关注点读 03/04。只想快速了解"能干什么",读 00 的第一、二节即可。

## 二、这套笔记回答的问题

- **Prow 是什么**:跑在 Kubernetes 上的事件驱动 CI/CD 系统和 GitHub 机器人,不是测试框架。
- **它能解决什么**:多仓库/多组织的统一 CI、chat-ops、OWNERS 审批、自动合并、状态上报、组织与分支保护治理。
- **plugin 怎么设计**:编译期注册到 8 类事件 map,hook 按 `plugins.yaml` 分发,命令由各 plugin 自己解析。
- **怎么扩展**:内置 plugin 改源码并重新构建 hook;external plugin 是独立 HTTP 服务,接收原始 webhook。
- **GitHub 怎么接**:webhook 只进 hook;出站走 PAT/GitHub App + ghproxy;Tide 消费 status/check 做合并决策。

## 三、边界

**覆盖**:

- 组件职责和一次 job 的主链路;
- plugin 的注册、分发、配置、help、external 契约;
- GitHub webhook、认证、API 限流、PR 合并与仓库治理。

**不覆盖**:

- 从零部署 Prow、TLS/Ingress、Secrets 管理;
- 具体 job 配置(presubmit/postsubmit/periodic)的字段全集;
- Gerrit、Pub/Sub、Jenkins/Tekton agent 的细节;
- 任何实测输出;文中命令均标为"未实测",执行前按实际环境替换主机名、路径和凭据。

## 四、参考

- [Prow 官方文档](https://docs.prow.k8s.io/)
- [kubernetes-sigs/prow](https://github.com/kubernetes-sigs/prow)
- [Prow Architecture](https://docs.prow.k8s.io/docs/overview/architecture/)
