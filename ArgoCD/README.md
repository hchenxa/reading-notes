# Argo CD 学习笔记

> 一套按序号读的 Argo CD 笔记:**00 讲概念与架构,01 讲环境、资源、YAML 和验证**,
> 02-05 再按同步机制、清单来源、多租户、生产化展开。
>
> - 版本基线:**Argo CD v3.5.6**(2026-10 当前 stable;v3.6 还在 RC,这周不跟)
> - 环境基线:macOS + colima(4 vCPU / 6 GiB)+ kind
> - 已实测:00 的概念整理、01 的安装与 `team-a` + ApplicationSet 验证、07 的 GitHub org/team SSO、08 的本地多租户 RBAC
> - 未逐条实测:02-05 是路线和实验设计;07 的 LDAP 未测,跑完把真实输出补进对应章节

## 一、文件索引

| 文件 | 内容 | 状态 |
|------|------|------|
| [00-概念与架构](00-概念与架构.md) | GitOps、desired / live / reconcile、组件、对象模型、状态机、v3 差异 | 已整理 |
| [01-环境搭建与首个应用](01-环境搭建与首个应用.md) | kind / colima、安装、部署的资源清单、YAML、验证测试 | 已实测 |
| [02-同步机制](02-同步机制.md) | 状态机、漂移、auto-sync / selfHeal / prune、diff、waves / hooks | 路线 |
| [03-清单来源与ApplicationSet](03-清单来源与ApplicationSet.md) | Helm、Kustomize、多源、ApplicationSet | 路线 |
| [04-多集群与多租户](04-多集群与多租户.md) | Cluster Secret、AppProject、RBAC、SSO | 路线 |
| [05-生产化与排障](05-生产化与排障.md) | HA、通知、监控、备份、升级、故障表 | 路线 |
| [06-源类型全解与扩展](06-源类型全解与扩展.md) | Directory/Helm/Kustomize/OCI、CMP 扩展框架、Terraform/Pulumi/Ansible 的接入 | 已整理(实验待做) |
| [07-SSO与Dex](07-SSO与Dex.md) | Dex 原理、GitHub / LDAP 连接器、RBAC、本地 kind 实验 | 已整理(GitHub org/team 已实测;LDAP 未实测) |
| [08-多租户RBAC](08-多租户RBAC.md) | AppProject 硬隔离、全局 RBAC、project roles、租户权限实验 | 已整理(本地用户已实测;SSO viewer 未实测) |
| [09-CLI验证手册](09-CLI验证手册.md) | SSO / RBAC / project role / Application 的 CLI 验证命令 | 已整理(核心命令已实测) |

**推荐顺序:00 → 01 → 02 → 03 → 04 → 05。** 06 是源类型扩展篇,07 是 SSO 专题,08 是多租户 RBAC 实验,09 是 CLI 验证手册,按需查阅。

如果只有一天:先读 00 的第一至五节,再跑 01。概念没建立起来之前,不要急着做实验;
否则 `Synced / OutOfSync`、`Healthy / Degraded`、`prune / selfHeal` 很容易混。

## 二、七天路线

| Day | 主题 | 读 / 做 |
|-----|------|--------|
| 1 | 概念 + 环境 + 第一个应用 | 00 + 01 |
| 2 | Application 生命周期与状态机 | 02 前半 |
| 3 | 同步引擎:diff / waves / hooks | 02 后半 |
| 4 | Helm / Kustomize / 多源 + ApplicationSet | 03 |
| 5 | 多集群 + AppProject / RBAC / SSO | 04 |
| 6 | 生产化:HA / 通知 / 监控 / 备份 / 升级 | 05 前半 |
| 7 | 排障 + capstone + 自测 | 05 后半 |

### 时间预算

| 时间 | 建议投入 | 说明 |
|------|---------|------|
| Day 1-2 | 每天 1.5 - 2 小时 | 概念 + 安装 + 状态机,先把主线跑通 |
| Day 3-4 | 每天 3 - 4 小时 | 同步引擎和清单来源,实验最多 |
| Day 5-6 | 每天 1.5 小时 | 多租户和生产化,读 + 小实验 |
| Day 7 | 2 - 3 小时 | 排障表 + capstone 复盘 |
| 合计 | **14 - 18 小时** | 只有 8 小时:00 + 01 + 02 必做,其余只读 |

## 三、这套笔记的边界

**一周能做到**:

- 解释 GitOps 的 pull 模型和 Argo CD 的组件分工;
- 从零安装、登录、卸载一套 Argo CD;
- 手写 Application / AppProject / ApplicationSet;
- 用 Helm / Kustomize / 多源仓库交付;
- 接第二个集群,按 project 做多租户;
- 拿出一份 HA / 通知 / 监控 / 备份 / 升级 checklist;
- 遇到常见 `OutOfSync` / `ComparisonError` 能按路径排查。

**这周不深入**:

- Argo Rollouts(渐进式发布)、Argo Workflows / Events;
- 自定义 CMP 插件开发、Source Hydrator / Impersonation(3.5 的 beta 特性;CMP 原理和最小实验见 [06](06-源类型全解与扩展.md));
- 上万 Application 的规模调优、Argo CD Agent 的拉模式。

## 四、当前实验环境

- `kind-argocd` 单节点集群,Kubernetes v1.36.1;Argo CD v3.5.6,7 个 Pod 全部 Running。
- `team-a` AppProject + `repo-team-a` Repository Secret + `guestbook-envs` ApplicationSet。
- 生成 `guestbook-dev` / `guestbook-prod`,分别部署到 `team-a-dev` / `team-a-prod`,均 `Synced + Healthy`。
- 详细安装、资源清单、YAML 和验证输出见 [01](01-环境搭建与首个应用.md)。

## 五、官方文档地图

| 主题 | 链接 | 什么时候看 |
|------|------|-----------|
| Getting Started | [getting_started](https://argo-cd.readthedocs.io/en/stable/getting_started/) | 01 |
| Architecture | [architecture](https://argo-cd.readthedocs.io/en/stable/operator-manual/architecture/) | 00 |
| Application Specification | [application-specification](https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/) | 00 / 02 |
| Auto Sync | [auto_sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/) | 02 |
| Sync Waves | [sync-waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/) | 02 |
| Diffing | [diffing](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/) | 02 |
| Helm | [helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/) | 03 |
| Kustomize | [kustomize](https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/) | 03 |
| Multiple Sources | [multiple_sources](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/) | 03 |
| OCI 制品源 | [oci](https://argo-cd.readthedocs.io/en/stable/user-guide/oci/) | 06 |
| Config Management Plugins | [config-management-plugins](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/) | 06 |
| Source Hydrator | [source-hydrator](https://argo-cd.readthedocs.io/en/stable/user-guide/source-hydrator/) | 06 |
| ApplicationSet | [applicationset](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) | 03 |
| Cluster Management | [cluster-management](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-management/) | 04 |
| Projects | [projects](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/) | 04 |
| RBAC | [rbac](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/) | 04 |
| SSO / User Management | [user-management](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/) | 04 |
| High Availability | [high_availability](https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/) | 05 |
| Notifications | [notifications](https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/) | 05 |
| Metrics | [metrics](https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/) | 05 |
| Disaster Recovery | [disaster_recovery](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/) | 05 |
| Upgrade Notes | [upgrading](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/) | 05 |
| FAQ | [faq](https://argo-cd.readthedocs.io/en/stable/faq/) | 排障 |

> 文档左上角有版本选择器。看 `stable` 就是当前 3.5.x,不要拿 2.x 的博客当准。

## 六、相关

- [00-概念与架构](00-概念与架构.md)
- [01-环境搭建与首个应用](01-环境搭建与首个应用.md)
- [文档写作规范](../docs/STYLE_GUIDE.md) —— 所有笔记的类型、元信息与章节格式
- [kubernetes/kind](../kubernetes/kind/) —— kind 集群配置与节点代理修复
- [Knative](../Knative/) —— 同样在本机 kind 上踩过资源 / 代理 / inotify 的坑
- [Istio](../Istio/) —— 多集群、Gateway 相关笔记
