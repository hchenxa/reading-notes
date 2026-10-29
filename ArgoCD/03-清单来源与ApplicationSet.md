# 03-清单来源:Helm、Kustomize、多源与 ApplicationSet

> 对应一周计划的 Day 4。前提是 01 已经跑通了 directory + Kustomize 的 `guestbook`。
> 这一篇把"清单从哪里来"讲全:Helm、Kustomize、多源仓库,以及用 ApplicationSet 批量生成 Application。
>
> 状态:路线 + 实验设计,Helm / 多源部分尚未逐条实测。

## 一、要回答的问题

- Argo CD 到底怎么执行 Helm?为什么 `helm list` 看不到它部署的 release?
- values 从哪来,优先级是什么?
- chart 在 Helm 仓库、values 在 Git 仓库,怎么组合?
- Kustomize 的 overlay / images 怎么用?
- ApplicationSet 和 app-of-apps 怎么选?
- 生成的 Application 归谁管,删 AppSet 会怎样?

## 二、Helm:Argo CD 只渲染,不安装

Argo CD 调 repo-server 执行 `helm template`,把输出当普通 YAML apply。所以:

- 集群里**没有 Helm release Secret**,`helm list` 看不到它。
- `helm rollback` 用不了,回滚靠 Argo CD 的 history 或 Git revert。
- Helm 的 hook 会被映射成 Argo CD 的 phase,但生命周期语义按 Argo CD 的规则走。

一个 Helm 类型的 Application:

```yaml
spec:
  source:
    repoURL: https://charts.example.com
    chart: myapp
    targetRevision: 1.2.3
    helm:
      releaseName: myapp
      valueFiles:
        - values-prod.yaml
      parameters:
        - name: image.tag
          value: "1.2.3"
      valuesObject:
        replicaCount: 2
```

values 的优先级从低到高:

| 优先级 | 来源 |
|--------|------|
| 1(最低) | chart 自带的 `values.yaml` |
| 2 | `valueFiles` 列表,后面的文件覆盖前面的 |
| 3 | `values`(内联 YAML 字符串) |
| 4 | `valuesObject`(内联结构化对象) |
| 5(最高) | `parameters`(`--set`) |

**不要同时用多种方式覆盖同一个字段**,否则排查会很痛苦。拿不准时看
`argocd app manifests` 的渲染结果。

## 三、多源:chart 和 values 分开放

chart 在 Helm 仓库、values 在自己的 Git 仓库,是常见做法:

```yaml
spec:
  sources:
    - repoURL: https://charts.example.com
      chart: myapp
      targetRevision: 1.2.3
      helm:
        valueFiles:
          - $values/envs/prod/values.yaml
    - repoURL: https://github.com/hchenxa/config.git
      targetRevision: main
      ref: values
```

`ref: values` 给第二个源起了个名字,第一个源用 `$values/...` 引用它。多源 Application 的
`status.sync.revisions` 会是一个数组,每个源一个 revision。

## 四、Kustomize

Kustomize 类型支持 `path`、`images`、`replicas`、`commonAnnotations` 等覆盖,
以及 `kustomize.buildOptions`(比如 `--load-restrictor LoadRestrictionsNone`)。
版本要固定,避免本地 `kustomize build` 和 repo-server 渲染结果不一致。

01 里的 `ArgoCD/labs/guestbook` 就是 Kustomize:Argo CD 看到 `kustomization.yaml`,
就会把 `deployment.yaml`、`service.yaml`、`configmap.yaml` 渲染成一个清单。

## 五、ApplicationSet:把重复的 Application 模板化

ApplicationSet 不直接创建业务资源,它**生成 Application**,再由 Application 去创建资源。
最常用的 List generator:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: guestbook
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - env: dev
            namespace: guestbook-dev
          - env: prod
            namespace: guestbook-prod
  template:
    metadata:
      name: 'guestbook-{{.env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/hchenxa/reading-notes.git
        targetRevision: main
        path: ArgoCD/labs/guestbook
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

生成器一览:

| Generator | 输入 | 典型场景 |
|-----------|------|---------|
| List | 手写的元素列表 | 少量固定环境 |
| Cluster | 注册到 Argo CD 的集群及其 label | 每个集群一套 |
| Git(directories / files) | Git 仓库里的目录或 values 文件 | 每个目录 / 文件一个环境 |
| SCMProvider | GitHub / GitLab 等组织的仓库列表 | 每个仓库一个应用 |
| PullRequest | PR 列表 | 每个 PR 一套预览环境 |
| Matrix / Merge | 组合多个 generator | cluster × env 的笛卡尔积 |
| ClusterDecisionResource | 外部决策资源 | 高级调度场景 |
| Plugin | 自定义插件 | 内置 generator 不够时 |

生命周期:

- 生成的 Application 带 ownerReference;删 AppSet 会删子 Application。
- 子 Application 默认带 `resources-finalizer`,会继续删业务资源;
  `syncPolicy.preserveResourcesOnDeletion: true` 可以保留。
- 不要手工改 AppSet 生成的 Application —— 下一次生成会被覆盖。

`app-of-apps` 和 ApplicationSet 怎么选:

| 维度 | app-of-apps | ApplicationSet |
|------|-------------|----------------|
| 定义方式 | 一个 Application 管一组 Application YAML | 控制器按 generator 生成 |
| 动态发现 | 要自己维护清单 | 内置 cluster / git generator |
| 删除行为 | 取决于每个子 Application 的 finalizer | ownerReference + preserve 开关 |
| 适合 | 少量、结构稳定 | 多环境、多集群、大量重复 |

## 六、验收

- [ ] 同一个 nginx 应用分别用 directory、Helm、Kustomize 三种方式部署。
- [ ] 用 List generator 生成 dev / prod 两个 Application,改 generator 能增删。
- [ ] 解释为什么 `helm list` 看不到 Argo CD 部署的 chart。
- [ ] 用 `argocd app manifests` 定位一次 Helm 渲染错误。
- [ ] 能说出 app-of-apps 和 ApplicationSet 各自适合什么场景。

## 七、下一步

- [04-多集群与多租户](04-多集群与多租户.md)
- [00-概念与架构](00-概念与架构.md) 6.3 与第三节
