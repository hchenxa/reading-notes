# Istio 升级中断机制:Gateway API 所有权切换与 Tag/Revision 的真相

> 资料核对日期:2026-09-27。源码基准 `istio/istio@9c8ba31`(master,sparse clone),
> 版本判断经 GitHub compare API 做 **commit ancestry 校验**,不是只读 release note 文本。
> 对应上游 issue [#59959](https://github.com/istio/istio/issues/59959)。
>
> 建议顺序:① 速览(第 0 节)→ ② 中断根因(第 2 节)→ ③ 手上有别的问题就跳第 3 节 →
> ④ 要决定"tag 还是 revision 名"看第 4 节 → ⑤ 正在排障直接上第 5 节 → ⑥ 操作流程第 6 节。

## 0. 一分钟速览

- **中断不是"滚动更新造成的"**,而是"**旧控制面把配置清空**"×"**新 Pod 还没就绪**"的叠加。
  滚动更新本身有 startupProbe / readinessProbe 保护,是安全的。
- 根因是 **config-emission 层的 `tagWatcher.IsMine()` 过滤器**(1.25 引入)。Gateway 一旦不属于本
  revision,整个资源从配置快照里消失 —— krt 发出的是 **delete**,而不是"跳过"。
  修复方式就是直接删掉它,落在 **1.29.5 / 1.30.2 / 1.31.0**。
- **tag 与具体 revision 名在 istiod 眼里完全等价。** `IsMine` 把两者当同一类值比较,
  tag 从未进入生成的 Pod spec。**tag 的优势是运维性的,不是机制性的。**
- **in-place 升级的风险是 istiod 可用性**(注入 webhook fail-closed、CA 断供、endpoint 推不下去),
  与这个配置清空 bug 是**两件独立的事**,不要混为一谈。
- **还有一半没修**:打了 `istio.io/rev` label 的 **HTTPRoute 仍然被 informer 级 revision 过滤**,
  对应修复 PR 已关闭未合并。这是当前最容易踩到的残余坑。

## 1. 背景:现象与时间线

### 1.1 环境与现象

集群里以多 revision 方式并存多个 istiod(`1-30-0` / `1-30-2` / `1-30-3` …),ingress 使用
Kubernetes Gateway API 的 `Gateway` 资源 + istio 的 `GatewayClass`。

操作是修改 `Gateway` 资源上的 `istio.io/rev` label 从一个 revision 切到另一个。观察到:

- Gateway 对应的 Deployment **正常滚动**,新 Pod 也能正常起来
- 但用循环 curl 打 LB 地址时,**在滚动窗口内有约 30 秒的连续失败**

关键特征是"新 Pod 是好的,老 Pod 也没崩,但流量就是断的"。

### 1.2 时间线

| 时间 | 事件 |
| --- | --- |
| 2026-04-21 | issue #59959 开启:"GatewayAPI Gateways 没有任何不中断流量的升级路径" |
| 2026-04-23 | 社区确认关键事实:**Gateway 天然只属于一个 istiod**,与 VirtualService / DestinationRule 的多控制面共存行为不同 |
| 2026-04-25 | 有人采用自建版本,基于 PR #59583 的 `DiscardResult` 方案 |
| 2026-05-09 | **#59583 被 stale bot 关闭,从未合并** |
| 2026-06-18 | **#60158 合入 master**;同日 backport:**#60624** → release-1.30,**#60627** → release-1.29 |
| 2026-06-24 | 1.29.5 与 1.30.2 发布,release note 收录该修复 |
| 2026-08-31 | 1.31.0 发布,从 master 直接继承该修复(master 的 `4e5bcf3f` 是 release-1.31 的祖先) |
| 2026-09-23 | 在 issue 中报告:1.30.2 → 1.30.3 的切换仍有约 30s 中断 |

## 2. Fix 之前的根因:那 30 秒是怎么来的

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
拿去比对 `GetMyTags()`。只要 label 值不再指向旧 istiod,旧 istiod **立刻** `IsMine=false`。

**环 3 —— 旧 Pod 无法"漂移"过去。**
gateway Pod 的 `CA_ADDR` 是**硬编码在 Pod spec 里**的,值取自 owner istiod 自己的 revision。
旧 Pod 一生只连 `istiod-1-30-2`,label 改了它也不会自动切到新控制面。

**环 4 —— 空推,而流量还在(真正的断点)。**
旧 istiod 把 Gateway 丢掉 → 给仍在连它的旧 gateway Pod 推送**空 xDS**(listener / route 全删)。
而旧 Pod 依然在 Service endpoints 里继续接收 LB 流量 → 表现为 `curl: (7) Failed to connect`。

**环 5 —— 新 Pod 需要 20~30 秒。**
新 istiod 要接管 webhook、改写 Deployment、滚出新 Pod,新 Pod 还要过 startupProbe(最长 30×1s)
与 readinessProbe(15s 周期)。这段窗口里**没有任何 Pod 能服务** —— 于是约 30 秒全量中断。

### 2.2 信号路径

```
改 label 的那一瞬间,两条通道的状态是错位的:

  旧 gateway Pod ──xDS──▶ istiod-1-30-2 ──▶ Gateway 已从配置剔除,推空 listener/route  ✗
  (rev: 1-30-2)                              ↑ 立刻断供

  新 gateway Pod ──xDS──▶ istiod-1-30-3 ──▶ 配置完整,但 Pod 要 20~30s 才就绪          ⏳
  (rev: 1-30-3)

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

### 2.5 修复做了什么

做法非常干脆:**把 config-emission 层的 `IsMine` 整个删掉**。因为它在另外两处已经是冗余的,
删掉后配置生成不再有 revision 排他性,而单例职责仍然被保护:

| 关注点 | 过滤器位置 | 修复后 |
| --- | --- | --- |
| **配置生成**(listener / route) | `gateway_collection.go` | **删除** —— 所有 revision 都为自己的 Pod 生成配置 |
| **status 写入** | `pilot/pkg/status/collections.go` `RegisterStatus` | **保留** —— 只有 owner 写,避免多控制面互相覆盖 |
| **Deployment 管理** | `gatewaycommon/deploymentcontroller.go:356` | **保留** —— 只有 owner 管,避免重复接管 |

代价是 `tagWatcher` 参数在配置生成层变成未使用(reviewer `ymesika` 专门提了这条)。
收益是行为与核心 CRD(VirtualService / DestinationRule)一致,并且**不依赖 last-known state**。

### 2.6 被否决的替代方案

另一条路线是 **PR #59583**:在提前返回之前调用 `ctx.DiscardResult()`,让 krt 保留上一次的输出而不是发 delete。

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

### 2.7 版本矩阵

| 版本区间 | 含修复 | PR / commit |
| --- | --- | --- |
| 1.28.x 及更早 | ❌ | 未 backport |
| 1.29.0 – 1.29.4 | ❌ | — |
| **1.29.5+** | ✅ | #60627 · `17c24702` |
| 1.30.0 / 1.30.1 | ❌ | — |
| **1.30.2+** | ✅ | #60624 · `9076b316` |
| **1.31.0+** | ✅ | #60158 · `4e5bcf3f`(master 继承) |

## 3. 另一条路径:In-place 升级为什么也会中断

这是与第 2 节**完全独立**的一类风险。in-place 的中断来源是**控制面可用性**,
而不是配置被清空 —— 两者不要混为一谈。

### 3.1 官方文档的表述

> **Warning** —— istio.io · In-place Upgrades
>
> Traffic disruption may occur during the upgrade process. To minimize the disruption,
> ensure that **at least two replicas of `istiod`** are running. Also, ensure that
> **PodDisruptionBudgets** are configured with a minimum availability of 1.
>
> …`istioctl` will in-place upgrade the Istio control plane **and gateways** to the new version.

### 3.2 机制:istiod 不可用的四个后果

| 后果 | 机制 |
| --- | --- |
| **注入 webhook fail-closed** | `istio-sidecar-injector` 的 `failurePolicy: Fail`。istiod 全挂时**新 Pod 根本创建不出来** —— 升级期间做任何 rollout 都会卡住。这是最常见的事故形态 |
| **CA / SDS 断供** | istiod 就是 CA。证书轮转失败;若正好有 workload 证书在这个窗口到期,mTLS 直接断 |
| **新 endpoint 推不下去** | 窗口内上线的 Pod 不会及时进入其他 Envoy 的 cluster —— 后端已经扩容,流量却过不去 |
| **已有 Envoy 不会清空配置** | xDS 断连时 Envoy 保留最后一份可用配置,所以**存量流量通常还在**。这正是 in-place 往往"看起来没事"的原因 |

### 3.3 与 revision 升级的本质差异

| 维度 | In-place | Revision / canary |
| --- | --- | --- |
| 控制面数量 | 只有一份,被滚掉时无兜底 | 新旧并存,旧的一直在服务 |
| 跨版本幅度 | 只能逐个 minor(1.29→1.30→1.31) | 允许跨 2 个 minor |
| 回滚 | 需再做一次 in-place 降级,且要换对应版本 `istioctl` | 翻 tag 或改 label 即可 |
| Gateway | 被 `istioctl upgrade` 一起原地滚动 | 可先并存两份再切量 |
| 主要风险 | istiod 可用性 | 所有权切换时的配置连续性 |

### 3.4 为什么纯 in-place 跨版本反而"没事"

issue 里的报告者提到:不用 revision、纯 `istioctl install -f values.yaml` 跨版本升级**反而一切正常**。
这完全说得通 —— 不用 revision 时配置过滤走 `LabelsInRevision`,而**没有 label 的对象是 global object**:

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

所有 istiod 都会生成配置,不存在"旧控制面清空配置"的问题。**所以 in-place 的风险是 istiod 可用性,
不是本文这个 gateway 清空 bug。**

## 4. 核心问题:Tag 与直接改 label 到底差在哪

**结论先说:在 istiod 眼里,这两者没有区别。**
社区里"换成 tag 就好了"的观察,最可能是**版本混淆** —— 真正起作用的是 fix,不是 tag。

### 4.1 代码:两种值走的是同一条比较

```go
// pkg/revisions/tag_watcher.go
func (p *tagWatcher) GetMyTags() sets.String {
    res := sets.New(p.revision)                          // 自己的 revision 永远算自己的
    for _, wh := range p.webhooksIndex.Lookup(p.revision) {
        res.Insert(wh.GetLabels()[label.IoIstioTag.Name]) // 再加上所有指向自己的 tag 名
    }
    // ... servicesIndex 同理
    return res
}

func (p *tagWatcher) IsMine(obj metav1.ObjectMeta) bool {
    selectedTag, ok := obj.Labels[label.IoIstioRev.Name]  // "canary" 或 "1-30-2"
    // ... 无 label 时回退到 namespace 的 istio.io/rev
    myTags := p.GetMyTags()
    return myTags.Contains(selectedTag) || /* default tag 的特殊分支 */
}
```

`myTags` 是「自己的 revision ∪ 指向自己的 tag」,两者是**同一类值**,没有任何优先级或宽容度差别。
把 label 写成 `canary`(tag)还是 `1-30-2`(revision 名),对 `IsMine` 而言完全一样。

### 4.2 反证:tag 从来没有进入过 Pod spec

生成 gateway Pod spec 时,用的是 `TemplateInput.Revision = d.revision` —— **owner istiod 自己的
revision**,而不是 Gateway 上写的那个值:

```yaml
# manifests/charts/istio-control/istio-discovery/files/kube-gateway.yaml
- name: CA_ADDR
  value: istiod{{- if not (eq .Values.revision "") }}-{{ .Values.revision }}{{- end }}.{{ .Values.global.istioNamespace }}.svc:15012
```

这同时说明了两件事:

1. **tag 从不参与 Pod spec 生成**,所以 tag 与 revision 名不可能在行为上有差别
2. `CA_ADDR` 是硬编码的,这正是第 2.1 节"旧 Pod 无法漂移"那一环的根据

### 4.3 那"换成 tag 就好了"怎么解释

最可能是**版本混淆**:那位报告者的起点是 **1.29.6**,而 backport #60627(`17c24702`)已经在 1.29.6 里。
也就是说他做的是一次"**已修复版本 → 已修复版本**"的升级,tag 只是恰好同时被换了。

他自己那句话其实已经把原因归给了版本,而不是 tag:

> "So you **WILL** have downtime from 1.30.0 to 1.30.2, but you **SHOULD** have none going from 1.30.2 to 1.30.3."

### 4.4 Tag 真正的好处(运维层,但都是实打实的)

| 好处 | 说明 |
| --- | --- |
| **完全不动对象** | 翻 tag 只改 `MutatingWebhookConfiguration istio-revision-tag-<tag>` 与 `Service istiod-<tag>` 两个集群级对象;所有 Gateway / namespace / Deployment 的 label **一个字节都不变** |
| **一次翻转、原子生效** | `istioctl tag set canary --revision 1-30-3 --overwrite` 改的是**同名** webhook(update,不是 delete + create),所有标了 `canary` 的对象在同一瞬间一起切过去 |
| **回滚成本极低** | 把 tag 翻回去就回滚了。硬编码 revision 名要再全改一遍,还得记得原值 |
| **有一张显式映射表** | `istioctl tag list` 随时可查;revision 名本身没有任何登记处(虽然 `--set revision=X` 也会隐式建一个同名 tag) |

关于第一点还有个额外好处:Gateway 的 label 会被**复制到它生成的 Deployment / Service / ServiceAccount**
上(`TemplateInput.InfrastructureLabels = gw.GetLabels()`),改 label 等于给这些对象也加了一次无谓 diff。

官方文档的措辞也正是这个角度:

> Revision tags are stable identifiers that point to revisions and can be used to avoid relabeling
> namespaces… Manually relabeling namespaces when moving them to a new revision can be
> **tedious and error-prone**.

### 4.5 一个真实的语义差异:无人认领的中间态

tag 与 revision 名有一处**确实不同**的行为,值得记住。

如果你**先把 label 改成 `1-30-3`,但 1-30-3 的 istiod 还没装好或还没就绪**,那么所有 istiod 的
`IsMine` 全为 false:

- **fix 之前**:没有任何控制面发配置 → **立刻全挂**
- **fix 之后**:旧 istiod 仍发配置所以流量不挂,但 **Deployment 没人管,新 Pod 永远起不来**,直到你装好为止

tag 流程天然避开这个状态:先装好新 revision,再翻 tag(`istioctl tag set --revision X` 还会校验
revision 存在)。换句话说,**"改 label"这个动作把"声明"和"实现"耦合在了一次操作里,顺序很容易做错。**

## 5. 排查:为什么在 1.30.2 → 1.30.3 还看到中断

代码上看 fix 已经生效,所以需要换方向。以下按可能性排序。

### 5.1 头号嫌疑:HTTPRoute 上也打了 `istio.io/rev`

**这是代码里仍然存在的、没被修掉的那一半。** `pilot/pkg/config/kube/gateway/controller.go:494`
的 `buildClient()`:

```go
func buildClient[I controllers.ComparableObject](...) krt.Collection[I] {
    filter := kclient.Filter{
        ObjectFilter: kubetypes.ComposeFilters(kc.ObjectFilter(), c.inRevision),
    }
    // all other types are filtered by revision, but for gateways we need to select tags as well
    if res == gvr.KubernetesGateway {          // ← 只有这一个 GVR 被豁免
        filter.ObjectFilter = kc.ObjectFilter()
    }
    ...
}
```

看 `buildClient` 的调用点(`controller.go:213-235`):Gateways 被豁免,但
**HTTPRoutes / GRPCRoutes / TLSRoutes / TCPRoutes / BackendTLSPolicies / ListenerSets 全都没有**。
而 `LabelsInRevision` 只在对象**没有** label 时才返回 true。

| HTTPRoute 上的 label | 老 istiod 的 informer | 结果 |
| --- | --- | --- |
| 不带 `istio.io/rev` | 看得见 | ✅ 安全 |
| 带了 `istio.io/rev: 1-30-2` | **根本没有这条 route** | ❌ 照断 |

而 issue 里的建议之一正是"给所有 HTTPRoute 打 `istio.io/rev`" —— 如果照做了,就会精准踩到这个坑。
修它需要豁免所有 route GVR,对应 PR **#59565 被关闭、未合并**,因此 issue #58840 至今只修了一半。

### 5.2 其他候选

- **Gateway CR 的 label 写了拼错或尚未安装的 revision 名** —— 见第 4.5 节的"无人认领的中间态"
- **滚动更新本身的成本**。注意 `30s` 这个数字也很像 `terminationGracePeriodSeconds` 或 drain 时间,
  而不是配置被清空。副本数 = 1 且没有 PDB 时,任何调度或拉镜像抖动都会变成真 downtime
- **确认 istiod 是否真的升级了** —— 要看 istiod 版本,不是 client 版本

### 5.3 排查清单

```bash
# 1. 确认所有控制面版本(重点看 istiod,不是 client)
istioctl version

# 2. 确认待升级对象的 revision 名真实存在
istioctl tag list
kubectl get mutatingwebhookconfiguration -l istio.io/tag

# 3. 确认 route 上有没有 revision label(头号嫌疑)
kubectl get httproute,grpcroute,tcproute,tlsroute -A -o json \
  | jq '.items[] | select(.metadata.labels["istio.io/rev"]) | .metadata'

# 4. 看副本数与滚动策略
kubectl -n <ns> get deploy <gw> -o jsonpath='{.spec.replicas}{"\n"}{.spec.strategy}{"\n"}'

# 5. 滚动期间盯 endpoints 会不会掉到 0
kubectl -n <ns> get endpoints <gw> -w
```

## 6. 推荐的零停机升级流程

1. **装新 revision,并确认就绪。**
   `istioctl install --set revision=1-30-3`,等到 `istiod-1-30-3` 全部 Ready 再进入下一步。
2. **Gateway 的 `istio.io/rev` 只写 tag,永不写具体 revision 名。**
   例如固定写 `canary`,让这个值在整个生命周期内不变。
3. **翻 tag 完成切换。**
   `istioctl tag set canary --revision 1-30-3 --overwrite` —— 一次原子切换,Gateway CR 完全不动。
4. **HTTPRoute 不要打 `istio.io/rev`。** 这是目前唯一仍未修复的坑。
5. **保证 istiod 版本不低于 1.29.5 / 1.30.2 / 1.31.0。**
6. **给 gateway Deployment 足够的安全边际。**
   至少 2 副本 + PodDisruptionBudget + `strategy.rollingUpdate.maxUnavailable: 0`。

## 7. 附录

### 7.1 关键代码位置

| 文件 | 关键符号 | 作用 |
| --- | --- | --- |
| `pkg/revisions/tag_watcher.go` | `IsMine` / `GetMyTags` | 所有权判定:revision 名与 tag 名在此等价 |
| `pkg/config/model.go` | `LabelsInRevision` | 核心 CRD 的 revision 过滤;无 label 即 global |
| `pilot/pkg/config/kube/gateway/gateway_collection.go` | `GatewayCollection` / `ListenerSetCollection` | 本次修复点:删掉 `IsMine` |
| `pilot/pkg/config/kube/gateway/controller.go` | `buildClient` / `inRevision` | **残留问题**:route 仍被 informer 级过滤 |
| `pilot/pkg/status/collections.go` | `RegisterStatus` | status 写入的 owner 过滤(保留) |
| `pilot/pkg/config/kube/gatewaycommon/deploymentcontroller.go` | `Reconcile` / `canManage` | Deployment 管理的 owner 过滤(保留) |
| `manifests/charts/istio-control/istio-discovery/files/kube-gateway.yaml` | `CA_ADDR` | proxy 连接地址硬编码为具体 revision |

### 7.2 PR 与 issue 对照

| 编号 | 标题 / 主题 | 状态 | 落入版本 |
| --- | --- | --- | --- |
| #60158 | gateway: don't drop config when istio.io/rev label changes | ✅ 已合并 | 1.31.0 |
| #60624 | \[release-1.30\] 同上(cherry-pick) | ✅ 已合并 | 1.30.2 |
| #60627 | \[release-1.29\] 同上(cherry-pick) | ✅ 已合并 | 1.29.5 |
| #54465 | Add tagged gateways to status and XDS(**引入该 bug**) | ✅ 已合并 | 1.25+ |
| #58292 | Prevent route resource status conflict in multi-revision installs | ✅ 已合并 | 1.27.4 / 1.28.1 |
| #59583 | krt: retain outputs on DiscardResult(替代方案) | ❌ 已关闭 | 从未合并 |
| #59565 | Do not filter gateway-api routes by revision at the informer level | ❌ 已关闭 | 从未合并 |
| #59959 | 本报告对应的 issue | 🔒 已关闭 | 由 #60158 关闭 |
| #58840 | HTTPRoutes are not globally applied when revision label is present | 🟡 stale 关闭 | 仅修复一半 |

### 7.3 参考资料

- [Canary Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/canary/)
- [In-place Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/in-place/)
- [Upgrading gateways · istio.io](https://istio.io/latest/docs/setup/additional-setup/gateway/#upgrading-gateways)
- [Issue #59959](https://github.com/istio/istio/issues/59959) ·
  [PR #60158](https://github.com/istio/istio/pull/60158) ·
  [PR #60624](https://github.com/istio/istio/pull/60624) ·
  [PR #60627](https://github.com/istio/istio/pull/60627)
- [PR #59583(已关闭)](https://github.com/istio/istio/pull/59583) ·
  [PR #59565(已关闭)](https://github.com/istio/istio/pull/59565) ·
  [PR #58292](https://github.com/istio/istio/pull/58292)
- [Issue #58840](https://github.com/istio/istio/issues/58840) ·
  [Issue #58865](https://github.com/istio/istio/issues/58865)

---

> 本报告为机制分析,结论以当时上游代码为准,升级前请以实际版本的源码复核。
> 本地调试用的 istio 源码 sparse clone 存放在 `/tmp/istio-src`(重启会丢,需要时重新 clone)。
