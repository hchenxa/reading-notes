# Istio Gateway 配置清空 Bug:#59959 的根因与修复

> 资料核对日期:2026-09-27。源码基准 `istio/istio@9c8ba31`(master,sparse clone)。
> 版本判断经 GitHub compare API 做 **commit ancestry 校验**,不是只读 release note 文本。
> 对应上游 issue [#59959](https://github.com/istio/istio/issues/59959),原始修复 PR
> [#60158](https://github.com/istio/istio/pull/60158)。

## 0. 这个 Bug 是什么

**一句话**:在 1.25 ~ 1.30.1 之间,只要一个 `Gateway` 的**归属控制面发生变化**,旧控制面会
**立刻把该 Gateway 从自己的配置快照里剔除**,并向仍在服务的旧 gateway Pod 推送一份**空 xDS 配置**
—— listener 和 route 全部删除。旧 Pod 还在 Service endpoints 里继续接收 LB 流量,于是表现为
**连接立即被拒**,直到新的 gateway Pod 起来,约 30 秒。

**关键:你不需要手动改 Gateway 的 label 就会触发。** 判定依据是"这个 label 值**当前解析到哪个
revision**",而不是"label 有没有被改过"。归属变化有四条途径(见 §1.1),其中**三条完全不碰
Gateway 对象** —— 而**正常的 revision 升级走的正是翻 tag 这条路**,原始 issue 就是这么触发的。

**它暴露了什么设计问题**:`Gateway` 资源天生只归属于一个 istiod。这与 VirtualService /
DestinationRule 等核心 CRD 在多控制面下的行为**完全不同** —— 后者只要不带 `istio.io/rev` label
就是 "global object",**每个 revision 都会读它、都会生成配置**。结果就是:
**使用 Gateway API 的网关在 revision 升级中没有不中断流量的路径。**

**影响面**:所有使用 Gateway API(`gatewayClassName: istio`)+ 多 revision 的集群。
单控制面(不用 revision)的集群不受影响,原因见 §2.5。

**修复版本**:

| 版本区间 | 含修复 | PR / commit |
| --- | --- | --- |
| 1.28.x 及更早 | ❌ | 未 backport |
| 1.29.0 – 1.29.4 | ❌ | — |
| **1.29.5+** | ✅ | #60627 · `17c24702` |
| 1.30.0 / 1.30.1 | ❌ | — |
| **1.30.2+** | ✅ | #60624 · `9076b316` |
| **1.31.0+** | ✅ | #60158 · `4e5bcf3f`(master 继承) |

## 1. 现象与时间线

### 1.1 触发条件:Gateway 的「归属控制面」发生变化

**先纠正一个容易搞错的框架**:这个 bug **不是**"你手动改 Gateway 的 label"才会踩到。
原始 issue 里报告者做的动作是:

> `istioctl tag set default --revision 1-29-2 --overwrite`

他**没有碰任何 Gateway 对象**。因为 `IsMine()` 判定的是"这个 label 值(**或它继承来的值**)
当前解析到哪个 revision",而不是"label 有没有被改过"。label 一直不动、只是它引用的 tag 被翻走,
归属照样翻转。

归属变化的四条途径 —— **其中三条完全不碰 Gateway 对象**:

| 途径 | 是否碰 Gateway | 典型场景 |
| --- | --- | --- |
| ① 改 Gateway 自己的 `istio.io/rev` label | ✅ 会 | 手动把一个网关切到新 revision |
| ② 翻 Gateway 引用的 tag 的指向 | ❌ 不会 | `istioctl tag set canary --revision <新> --overwrite` |
| ③ 翻 `default` tag 的指向 | ❌ 不会 | `istioctl tag set default --revision <新>` —— **原始 issue 就是这个** |
| ④ 改 Gateway 所在 **namespace** 的 `istio.io/rev` label | ❌ 不会 | Gateway 自己没写 label 时会**继承 namespace 的** |

**②③④ 才是 revision 升级的正常路径** —— 标准流程里没人会去 patch 每个网关的 label,
而是翻 tag 或改 namespace。所以这个 bug 会在**没有任何人手改 Gateway label** 的情况下发作。

> **补充**:如果 Gateway 自己没写 label、所在 namespace 也没写,`selectedTag` 会是空字符串,
> 判定落到 `myTags.Contains("default") || (weAreDefaultRevision && !otherDefaultTagExists)` ——
> 也就是**该网关跟着 `default` revision 走**。这正是为什么翻 `default` tag 会把一批
> 没写 label 的网关一起搬走,也解释了原始 issue 的现象。

### 1.2 现象

观察到:

- Gateway 对应的 Deployment **正常滚动**,新 Pod 也能正常起来
- 但用循环 curl 打 LB 地址时,**滚动窗口内有约 30 秒的连续失败**
- 关键特征:**新 Pod 是好的,老 Pod 也没崩,但流量就是断的**

issue 里的原始描述:

> As soon as I do a `istioctl tag set default --revision 1-29-2 --overwrite`, my `Gateway`
> deployment pods start rolling over to the new version immediately. … Any requests that are
> going to the existing 1.28 pods blows up … This process takes around 30 seconds or so of
> traffic breaking.

### 1.3 时间线

| 时间 | 事件 |
| --- | --- |
| 2026-04-21 | issue #59959 开启:"GatewayAPI Gateways 没有任何不中断流量的升级路径" |
| 2026-04-23 | 社区确认关键事实:**Gateway 天然只属于一个 istiod**,与核心 CRD 的多控制面共存行为不同 |
| 2026-04-25 | 有人采用自建版本,基于 PR #59583 的 `DiscardResult` 方案 |
| 2026-05-09 | **#59583 被 stale bot 关闭,从未合并** |
| 2026-06-18 | **#60158 合入 master**;同日 backport:**#60624** → release-1.30,**#60627** → release-1.29 |
| 2026-06-24 | 1.29.5 与 1.30.2 发布,release note 收录该修复 |
| 2026-08-31 | 1.31.0 发布,从 master 直接继承该修复 |

## 2. 根因

答案写在**修复代码自己的注释**里。PR #60158 在 `gateway_collection.go` 留下了这段说明:

```go
// pilot/pkg/config/kube/gateway/gateway_collection.go · ListenerSetCollection
//
// Note: tagWatcher.IsMine() is intentionally not filtered at this config-emission layer. Filtering
// here caused a temporary outage when a Gateway's or ListenerSet's istio.io/rev label was changed:
// the prior owning control plane immediately dropped the resource and pushed empty xDS config to
// pods still running on the old revision (see https://github.com/istio/istio/issues/59959).
```

### 2.1 故障链的五个环节

**环 1 —— 一个多余且致命的过滤器。**

从 1.25 起(PR #54465,为修 #54458),`GatewayCollection()` 与 `ListenerSetCollection()` 的回调开头有:

```go
if !tagWatcher.Get(ctx).IsMine(obj.ObjectMeta) {
    return nil, nil
}
```

这**不是**"不写 status"。在 krt 里返回 nil 意味着"这个 key 没有输出",等价于**发出 delete** ——
Gateway 从整个配置快照中消失。

**环 2 —— `IsMine` 的判定方式。**

`pkg/revisions/tag_watcher.go` 取对象的 `istio.io/rev` 值(没有则回退到 namespace 的同名 label),
拿去比对 `GetMyTags()`:

```go
func (p *tagWatcher) GetMyTags() sets.String {
    res := sets.New(p.revision)                          // 自己的 revision 永远算自己的
    for _, wh := range p.webhooksIndex.Lookup(p.revision) {
        res.Insert(wh.GetLabels()[label.IoIstioTag.Name]) // 再加上所有指向自己的 tag 名
    }
    // ... servicesIndex 同理
    return res
}

func (p *tagWatcher) IsMine(obj metav1.ObjectMeta) bool {
    selectedTag, ok := obj.Labels[label.IoIstioRev.Name]
    if !ok {
        ns := p.namespaces.Get(obj.Namespace, "")
        if ns == nil {
            return true                                  // ① namespace 都取不到 → 人人有份
        }
        selectedTag = ns.Labels[label.IoIstioRev.Name]   // ② 回退到 namespace 的 label
    }
    myTags := p.GetMyTags()
    // ... 再算出 otherDefaultTagExists / weAreDefaultRevision
    return myTags.Contains(selectedTag) ||
        selectedTag == "" && (myTags.Contains("default") ||   // ③ 空值 → 跟 default revision 走
            (weAreDefaultRevision && !otherDefaultTagExists))
}
```

**关键:只要这个值当前解析到的不再是旧 istiod,旧 istiod 立刻 `IsMine=false`。**
而这个值可以来自 **Gateway 自己**、也可以来自 **它所在的 namespace**;label 本身甚至可以
**一个字节都没变** —— 变的是 `myTags`(它引用的 tag 被翻走了)。这就是 §1.1 那四条途径的由来。

**环 3 —— 旧 Pod 无法"漂移"过去。**

gateway Pod 的 `CA_ADDR` 是**硬编码在 Pod spec 里**的,值取自 owner istiod 自己的 revision:

```yaml
# manifests/charts/istio-control/istio-discovery/files/kube-gateway.yaml
- name: CA_ADDR
  value: istiod{{- if not (eq .Values.revision "") }}-{{ .Values.revision }}{{- end }}.{{ .Values.global.istioNamespace }}.svc:15012
```

旧 Pod 一生只连 `istiod-1-28-6`,label 改了它也不会自动切到新控制面。

**环 4 —— 空推,而流量还在(真正的断点)。**

旧 istiod 把 Gateway 丢掉 → 给仍在连它的旧 gateway Pod 推送**空 xDS**(listener / route 全删)。
而旧 Pod 依然在 Service endpoints 里继续接收 LB 流量 → 表现为 `curl: (7) Failed to connect`。

**环 5 —— 新 Pod 需要 20~30 秒。**

新 istiod 要接管 webhook、改写 Deployment、滚出新 Pod,新 Pod 还要过 startupProbe(最长 30×1s)
与 readinessProbe(15s 周期)。这段窗口里**没有任何 Pod 能服务** —— 于是约 30 秒全量中断。

> **关键认知**:这不是"滚动更新造成的",而是「**旧控制面把配置清空**」×「**新 Pod 还没就绪**」
> 的叠加。滚动更新本身有 startupProbe / readinessProbe 保护,是安全的。

### 2.2 信号路径

```
改 label 的那一瞬间,两条通道的状态是错位的:

  旧 gateway Pod ──xDS──▶ istiod-1-28-6 ──▶ Gateway 已从配置剔除,推空 listener/route  ✗
  (rev: 1-28-6)                              ↑ 立刻断供

  新 gateway Pod ──xDS──▶ istiod-1-29-2 ──▶ 配置完整,但 Pod 要 20~30s 才就绪          ⏳
  (rev: 1-29-2)

旧通道立刻断供,新通道还没建好 —— 中间这段就是那 30 秒。
```

`CA_ADDR` 决定了一个 Pod 属于哪条通道,而**它在 Pod 重建之前不会改变**。

### 2.3 这是一个回归,不是设计如此

该过滤器由 **PR #54465**(*Add tagged gateways to status and XDS*,2025-01 合入)引入,
目的是修 #54458「打了 tag 的 Gateway 拿不到 XDS」。它解决了一个真实问题,
但把过滤器放在了**配置生成层**,副作用就是所有权一变、配置立刻被清空。

### 2.4 常见误判:被清空的是 xDS,不是 route status

issue 里有人说"被清空的是 HTTPRoute 的 status",并把线索指向 PR #58292。
但 #58292 只改 **status 写入**(在 `pilot/pkg/status/collections.go` 的 `RegisterStatus` 里加
`IsMine` 过滤),**完全不碰 xDS 配置生成**。

status 变空只是同一个根因的旁证 —— Gateway 被丢掉后,route 找不到 parent,于是 status 也空了。
**顺着 status 这条线查会走偏。**

### 2.5 为什么单控制面(不用 revision)不受影响

不用 revision 时,配置过滤走 `LabelsInRevision`,而**没有 label 的对象是 global object**:

```go
// pkg/config/model.go:111
func LabelsInRevision(lbls map[string]string, rev string) bool {
    configEnv, f := lbls[label.IoIstioRev.Name]
    if !f {
        // This is a global object, and always included
        return true
    }
    ...
}
```

所有 istiod 都会生成配置,不存在"旧控制面清空配置"的问题。这也解释了 issue 里报告者的观察:
不用 revision、纯 `istioctl install -f values.yaml` 跨版本升级**反而一切正常**。

## 3. 修复

### 3.1 做法:删掉 config-emission 层的 `IsMine`

修复非常干脆 —— 直接**删掉**那个过滤器,因为它在另外两处已经是冗余的:

| 关注点 | 过滤器位置 | 修复后 |
| --- | --- | --- |
| **配置生成**(listener / route) | `gateway_collection.go` | **删除** —— 所有 revision 都为自己的 Pod 生成配置 |
| **status 写入** | `pilot/pkg/status/collections.go` `RegisterStatus` | **保留** —— 只有 owner 写,避免多控制面互相覆盖 |
| **Deployment 管理** | `gatewaycommon/deploymentcontroller.go:356` | **保留** —— 只有 owner 管,避免重复接管 |

代价是 `tagWatcher` 参数在配置生成层变成未使用(reviewer `ymesika` 专门提了这条)。
收益是行为与核心 CRD(VirtualService / DestinationRule)一致,并且**不依赖 last-known state**。

Release note 原文:

> **Fixed** a brief traffic outage when changing the `istio.io/rev` label on a Kubernetes
> `Gateway` (or `ListenerSet`). The previously-owning control plane no longer drops the resource
> and pushes empty xDS config to gateway pods that are still running on the old revision.

### 3.2 被否决的替代方案 #59583

另一条路线是在提前返回之前调用 `ctx.DiscardResult()`,让 krt 保留上一次的输出而不是发 delete:

```diff
  if !tagWatcher.Get(ctx).IsMine(obj.ObjectMeta) {
+     ctx.DiscardResult()
      return nil, nil
  }
```

howardjohn 的两条否决理由,恰好解释了为什么最终方案是"删掉"而不是"打补丁":

> "我们改了一条代码路径,但可能还有 100 条路径对 revision 有隐性依赖并会生成错误配置,
> 很难确信补全了所有正确的地方。"
>
> "这个方案依赖存在 last known config。想象一个新起的 istiod 副本 —— 我们又会回到坏配置的状态。"

#59583 于 2026-05-09 被 stale bot 关闭,**从未合并**。有人用自建版本生产过,但上游没有接受。

### 3.3 修复没有覆盖到的地方

**HTTPRoute 这一半至今没修。** `pilot/pkg/config/kube/gateway/controller.go:494` 的 `buildClient()`:

```go
filter := kclient.Filter{
    ObjectFilter: kubetypes.ComposeFilters(kc.ObjectFilter(), c.inRevision),
}
// all other types are filtered by revision, but for gateways we need to select tags as well
if res == gvr.KubernetesGateway {          // ← 只有这一个 GVR 被豁免
    filter.ObjectFilter = kc.ObjectFilter()
}
```

看调用点(`controller.go:213-235`):Gateways 被豁免,但
**HTTPRoutes / GRPCRoutes / TLSRoutes / TCPRoutes / BackendTLSPolicies / ListenerSets 全都没有**。
而 `LabelsInRevision` 只在对象**没有** label 时才返回 true。

| HTTPRoute 上的 label | 老 istiod 的 informer | 结果 |
| --- | --- | --- |
| 不带 `istio.io/rev` | 看得见 | ✅ 安全 |
| 带了 `istio.io/rev: 1-28-6` | **根本没有这条 route** | ❌ 同类中断 |

修它需要豁免所有 route GVR,对应 PR **#59565 被关闭、未合并**,因此 issue
[#58840](https://github.com/istio/istio/issues/58840) 至今只修了一半。

## 4. 修复之后仍然会遇到的同类现象

这个 bug 修掉的是「旧控制面推空配置」。但在多 revision 升级中,**还有另一条完全独立的路径**
会造成同样的"约 30 秒连接中断",而且它在 1.30.2 → 1.30.3 这种"两侧都已修复"的升级里依然存在 ——
因为两个操作实际**写入的对象集合不同**。

那部分内容见另一篇:[升级中断排查](升级中断排查.md)。

## 5. 附录

### 5.1 关键代码位置

| 文件 | 关键符号 | 作用 |
| --- | --- | --- |
| `pkg/revisions/tag_watcher.go` | `IsMine` / `GetMyTags` | 所有权判定:revision 名与 tag 名在此等价 |
| `pkg/config/model.go` | `LabelsInRevision` | 核心 CRD 的 revision 过滤;无 label 即 global |
| `pilot/pkg/config/kube/gateway/gateway_collection.go` | `GatewayCollection` / `ListenerSetCollection` | **本次修复点**:删掉 `IsMine` |
| `pilot/pkg/config/kube/gateway/controller.go` | `buildClient` / `inRevision` | **残留问题**:route 仍被 informer 级过滤 |
| `pilot/pkg/status/collections.go` | `RegisterStatus` | status 写入的 owner 过滤(保留) |
| `pilot/pkg/config/kube/gatewaycommon/deploymentcontroller.go` | `Reconcile` / `canManage` | Deployment 管理的 owner 过滤(保留) |

### 5.2 PR 与 issue 对照

| 编号 | 标题 / 主题 | 状态 | 落入版本 |
| --- | --- | --- | --- |
| #60158 | gateway: don't drop config when istio.io/rev label changes | ✅ 已合并 | 1.31.0 |
| #60624 | \[release-1.30\] 同上(cherry-pick) | ✅ 已合并 | 1.30.2 |
| #60627 | \[release-1.29\] 同上(cherry-pick) | ✅ 已合并 | 1.29.5 |
| #54465 | Add tagged gateways to status and XDS(**引入该 bug**) | ✅ 已合并 | 1.25+ |
| #58292 | Prevent route resource status conflict in multi-revision installs | ✅ 已合并 | 1.27.4 / 1.28.1 |
| #59583 | krt: retain outputs on DiscardResult(替代方案) | ❌ 已关闭 | 从未合并 |
| #59565 | Do not filter gateway-api routes by revision at the informer level | ❌ 已关闭 | 从未合并 |
| #59959 | 本 Bug 对应的 issue | 🔒 已关闭 | 由 #60158 关闭 |
| #58840 | HTTPRoutes are not globally applied when revision label is present | 🟡 stale 关闭 | 仅修复一半 |

### 5.3 参考资料

- [Issue #59959](https://github.com/istio/istio/issues/59959) ·
  [PR #60158](https://github.com/istio/istio/pull/60158) ·
  [PR #60624](https://github.com/istio/istio/pull/60624) ·
  [PR #60627](https://github.com/istio/istio/pull/60627)
- [PR #59583(已关闭)](https://github.com/istio/istio/pull/59583) ·
  [PR #59565(已关闭)](https://github.com/istio/istio/pull/59565) ·
  [PR #58292](https://github.com/istio/istio/pull/58292)
- [Issue #58840](https://github.com/istio/istio/issues/58840)

---

> 本报告为机制分析,结论以当时上游代码为准,升级前请以实际版本的源码复核。
