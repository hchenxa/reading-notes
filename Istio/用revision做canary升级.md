# Istio 用 revision 做 canary 升级：从选型到零停机，以及那两个让你断流 30 秒的坑

> Gateway 上写什么，决定了你这次升级会不会断流量。

Istio 的升级一直是个让人心里没底的操作。官方给了两条路：`istioctl upgrade` 的原地（in-place）升级，和基于 revision 的 canary 升级。

大多数团队的路径是：先在测试集群 `istioctl upgrade` 试一把，发现「居然没事」，于是生产也照做。这个归纳非常危险 —— 因为 in-place 升级「看起来没事」，恰恰是它的机制决定的：**存量 Envoy 会保留最后一份可用配置**，只要升级窗口里没有新 Pod 要创建，你什么都感觉不到。

**先说结论：revision 升级只有一种姿势是对的 —— Gateway 上永远写 tag（比如 `istio.io/rev=prod`），升级时只翻 tag 的指向，Gateway 对象一个字节都不改。** 这样全程没有服务中断：tag 指向变了之后，gateway 对应的 Deployment 会**自动做 rolling**，这是预期行为，而且因为没有别的对象被改写，这次滚动是干净的。

反过来，如果图省事把 revision 名直接写死在 Gateway 上，每次升级去 patch 它，就会有约 30 秒的中断。下面会讲清楚为什么 —— 以及一个版本前提：**能不能用这套姿势，取决于你正在跑的旧 istiod 版本**。

这篇文章是把 istio.io 官方文档、上游 issue #59959、以及 `istio/istio@9c8ba31` 的源码对照读完之后整理的完整笔记。**机制部分是代码直读，版本判断经过 commit ancestry 校验** —— 不是只读 release note 抄结论。

## 01 结论先行：revision + tag，Gateway 永不动

### 三条路，只有一条不会断

| 做法 | 升级时改什么 | 服务中断 |
| --- | --- | --- |
| **Gateway 写 tag**（`istio.io/rev=prod`） | 只翻 tag 的指向 | **无中断** |
| Gateway 写 revision 名（`istio.io/rev=1-30-2`） | `kubectl patch` Gateway label | **约 30 秒** |
| 不用 revision，走 in-place | `istioctl upgrade` | 风险最高，见第 02 章 |

第一行的「无中断」有一个前提：**你的旧控制面已经带上 #59959 的修复**。这个前提很重要，第 06 章单独讲。

### 推荐姿势：四步

1. **装新 revision。** `istioctl install --set revision=<新>`，等它全部 Ready。
2. **Gateway / namespace 上只写 tag，永不写 revision 名。** 例如固定写 `prod`，让这个值在整个生命周期内不变。
3. **翻 tag 完成切换。** `istioctl tag set prod --revision <新> --overwrite`。
4. **观察，然后卸掉旧 revision。** `istioctl uninstall --revision <旧> -y`。

第 3 步是全部动作。**Gateway 对象从头到尾没有被碰过。**

### 一个必须先说清楚的行为

翻完 tag，你会发现 gateway 的 Deployment **自己开始 rolling 了**。这不是意外 —— tag 从不进入 Pod spec，`CA_ADDR` 取的是 owner istiod 自己的 revision：

```yaml
# manifests/charts/istio-control/istio-discovery/files/kube-gateway.yaml
- name: CA_ADDR
  value: istiod{{- if not (eq .Values.revision "") }}-{{ .Values.revision }}{{- end }}.{{ .Values.global.istioNamespace }}.svc:15012
```

tag 指向一变，owner istiod 就变了，pod template 里的 `CA_ADDR` 跟着变，Deployment 自然滚动。所以**两种姿势下 Pod 都会滚**，差别不在「滚不滚」，而在**滚动之外还改了什么**。

- **写 tag**：只有这一次干净的 Pod 滚动。没有入口对象被改写，滚动有 startupProbe / readinessProbe 保护，流量不断。
- **写 revision 名**：Pod 滚动 ＋ 6 个生成对象被改写，两个扰动窗口叠加 —— 这就是那 30 秒的来源，第 07 章展开。

> 这篇文章剩下的部分，就是解释「为什么只有这一种姿势是对的」。

## 02 为什么 in-place 升级是场赌博

`istioctl upgrade` 做的事是：把已安装的 Istio **原地**换到新版本 —— 控制面和 gateway 一起被替换，集群里始终只有一份控制面。

官方文档给的风险提示只有一句话：

> **Warning**: Traffic disruption may occur during the upgrade process. To minimize the disruption, ensure that **at least two replicas of `istiod`** are running. Also, ensure that **PodDisruptionBudgets** are configured with a minimum availability of 1.

这句话背后的机制，比它读起来严重得多。

### 核心：没有第二个控制面兜底

revision 升级时新老 istiod 并存，老的持续服务老 Pod；in-place 时 **istiod 自己先被滚掉，没有任何 fallback**。由此产生四个后果：

| 后果 | 机制 |
| --- | --- |
| **注入 webhook fail-closed** | `istio-sidecar-injector` 的 `failurePolicy: Fail`。istiod 全挂时**新 Pod 根本创建不出来** —— 升级期间做任何 rollout 都会卡住。这是最常见的事故形态 |
| **CA / SDS 断供** | istiod 就是 CA。证书轮转失败；若正好有 workload 证书在这个窗口到期，mTLS 直接断 |
| **新 endpoint 推不下去** | 窗口内上线的 Pod 不会及时进入其他 Envoy 的 cluster —— 后端已经扩容，流量却过不去 |
| **已有 Envoy 不会清空配置** | xDS 断连时 Envoy 保留最后一份可用配置，所以**存量流量通常还在**。这正是 in-place 往往「看起来没事」的原因 |

### 为什么它常常「看起来没事」

两个原因叠在一起。

第一，就是上面表格的最后一行：Envoy 断连时保留最后一份可用配置，存量流量不受影响。

第二，**没有 label 的对象是 global object**。配置过滤走 `LabelsInRevision`：

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

所有 istiod 都会生成配置，不存在「旧控制面清空配置」的问题。**所以 in-place 的风险是 istiod 可用性，不是配置连续性** —— 这两件事不要混。

反过来说：只要升级窗口里出现了新的 Pod 创建需求（业务自己在发版、HPA 扩容、节点故障迁移），fail-closed 立刻生效。你没踩到，可能只是运气。

### 另外两个结构性劣势

- **不可回滚**。出问题只能再 in-place 降级，还得换对应版本的 `istioctl`，暴露窗口翻倍。
- **gateway 也在原地被升**。`istioctl upgrade` 会把 gateway Deployment 一起滚。没有第二份 gateway 可以分流时，这个滚动窗口就是纯 downtime。

### 实操与其硬约束

```bash
# 前置检查
istioctl x precheck

# 执行升级（原来用 -f 装的必须传同样的 -f，用 --set 装的必须传同样的 --set，
# 否则自定义配置会被还原成默认 profile）
istioctl upgrade -f <原来那份配置>

# 升级完成后，手动滚动数据面
kubectl rollout restart deployment -n <你的业务命名空间>
```

三条前置约束值得单独记：

- **已安装版本不能比目标版本低超过一个 minor**。例如升到 1.31，当前必须是 1.30.x。
- 必须是**用 `istioctl install` / `istioctl upgrade` 那条路径装的**。
- **不通用**：`istioctl upgrade` 不支持用 `--revision` 安装出来的控制面，会直接报错。用哪种装的，就只能用哪种升。

## 03 心智模型：同一集群里并存两份控制面

用 `revision` 安装参数，可以在同一集群里**并存多份完整、互相独立的控制面**。每份 revision 有自己的 `Deployment`、`Service`、注入 webhook：

> Each revision is a full Istio control plane implementation with its own `Deployment`, `Service`, etc.

升级 = 装一份新的 revision，把工作负载一批批切过去，最后删掉旧的。官方对这条路径的态度非常明确：

> ...much safer than doing an in-place upgrade and is the recommended upgrade method.

具体换来什么：

| 维度 | In-place | Revision / canary |
| --- | --- | --- |
| 控制面数量 | 只有一份，被滚掉时无兜底 | 新旧并存，旧的一直在服务 |
| 跨版本幅度 | 只能逐个 minor（1.29→1.30→1.31） | **允许跨 2 个 minor** |
| 灰度能力 | 无（一次全切） | 有（namespace / Gateway 粒度） |
| 回滚 | 再做一次 in-place 降级 + 换 istioctl 版本 | 切回 label / tag |
| 数据面 | 升级完手动 `kubectl rollout restart` | 迁 namespace 后 `rollout restart` |
| 资源开销 | 小 | 并存期间约 2 倍控制面资源 |

### 风险没有消失，只是换了地方

这是全文最值得记住的一句话：**两种方式都会中断，但中断的来源完全不同。**

| | In-place | Revision |
| --- | --- | --- |
| 中断来源 | **istiod 不可用**（注入 webhook fail-closed、CA 断供、endpoint 推不下去） | **所有权切换时的配置连续性** |
| 为什么 | 没有第二个控制面兜底 | 新旧控制面交接时，配置和 Deployment 的归属要转移 |
| 排查起点 | istiod 副本数、PDB、升级窗口内的 Pod 创建失败事件 | 归属切换时「哪些对象被改写了」、旧 Pod 是否还拿得到配置 |

而 revision 这条路上的「所有权切换」，正是第 05 到 07 章的主题。

## 04 Revision canary 实操三步

### 步骤 01 装新 revision

```bash
# 0. 前置检查（推荐）
istioctl x precheck

# 1. 装新 revision —— 老控制面完全不受影响
istioctl install --set revision=1-31-0

# 装完可以看到两份并存
kubectl get pods -n istio-system -l app=istiod
# istiod-1-30-2-xxx   1/1   Running
# istiod-1-31-0-yyy   1/1   Running
```

### 步骤 02 把数据面迁过去

**方式 A：直接标 revision**（简单，但对象多时难维护）

```bash
# 注意：istio-injection 优先级高于 istio.io/rev，必须先删掉它，否则不会生效
kubectl label namespace <ns> istio-injection-
kubectl label namespace <ns> istio.io/rev=1-31-0 --overwrite

# 然后重启 Pod 触发重新注入
kubectl rollout restart deployment -n <ns>
```

**方式 B：用 revision tag**（推荐，也就是第 01 章的姿势）

tag 是**稳定别名**，指向某个 revision。升级时不用改任何对象的 label，只翻 tag 的指向：

```bash
# 建立 tag
istioctl tag set prod-stable --revision 1-30-2
istioctl tag set prod-canary --revision 1-31-0

# namespace / Gateway 上写的是 tag 名，而不是 revision 名
kubectl label namespace <ns> istio.io/rev=prod-stable --overwrite

# —— 之后要升到 1-31-0，只改 tag 指向 ——
istioctl tag set prod-stable --revision 1-31-0 --overwrite
kubectl rollout restart deployment -n <ns>
```

官方原话：

> Notice that no relabeling was required to migrate workloads to the new revision.

### 步骤 03 卸掉旧控制面

```bash
# 确认没有工作负载还在用旧 revision 后
istioctl uninstall --revision 1-30-2 -y
```

> 卸载只会删掉指定 revision 的资源，**不会**删掉与其他控制面共享的集群级资源。

### 顺带记住 default tag 的特殊语义

tag `default` 指向的 revision 是「默认 revision」，额外承担三件事：

- 为 `istio-injection=enabled`、`sidecar.istio.io/inject=true`、`istio.io/rev=default` 注入 sidecar
- 校验 Istio 资源
- **抢占非默认 revision 的 leader 锁**，执行单例 mesh 职责

第一条和第三条是第 06 章的引线，记住它们。

### 迁移顺序与回滚注意

- 迁移是**逐个 namespace / 逐个 Gateway** 做的，可以随时停下来观察。
- **回滚**：把 label 或 tag 切回旧 revision 即可，代价远低于 in-place。
- 如果之前对 gateway 做过 in-place 升级，`istioctl uninstall` **不会**自动把它恢复成旧 revision 的 gateway。需要手工用**对应旧版本的 `istioctl`** 把旧 gateway 装回来。官方提示：为避免 downtime，**先确认旧 gateway 已经跑起来，再进行 canary 卸载**。

## 05 为什么「只写 tag」是硬性要求

### 在「所有权判定」这一层，tag 和 revision 名完全等价

revision 的 tag 和 revision 名，看起来只是两种写法。在代码里判定「这个对象归不归我管」的是 `IsMine`：

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
    return p.GetMyTags().Contains(selectedTag) || /* default tag 的特殊分支 */
}
```

`myTags` 是「自己的 revision ∪ 指向自己的 tag」，两者是**同一类值**，没有任何优先级或宽容度差别。把 label 写成 `canary`（tag）还是 `1-30-2`（revision 名），对 `IsMine` 而言完全一样。

**但这个等价只到这一层为止。** 两个操作本身并不等价，差别在**实际写入的对象集合**。

### 分水岭：一个默认开启的开关

`PILOT_ENABLE_GATEWAY_API_COPY_LABELS_ANNOTATIONS` **默认为 true**（`pilot/pkg/features/experimental.go:152`），它会执行 `maps.Clone(gw.GetLabels())` —— 把 Gateway 的 `metadata.labels` **原样复制到它生成的所有对象上**。在 `kube-gateway.yaml` 里，`.InfrastructureLabels` 出现在 6 处：

| 行号 | 对象 |
| --- | --- |
| L10 | ServiceAccount |
| L33 | Deployment `metadata.labels` |
| L66 | **Pod template labels** |
| L328 | **Service（`type: LoadBalancer`）** |
| L365 / L391 | HPA / PDB |

于是两条路径的写入集合完全不同：

| | 写 revision 名（patch label） | 写 tag（翻 tag） |
| --- | --- | --- |
| Gateway 对象本身 | **被用户改写**（resourceVersion 变，唤醒所有 Gateway watcher） | 从不被碰 |
| Deployment pod template 的 rev 注解 / `CA_ADDR` / image | 变 | 变 |
| Deployment pod template 的 **labels** | **变**（1.30.2 → 1.30.3） | 不变（恒为 `stable`） |
| **Service（LB）metadata.labels** | **变** | **不变** |
| ServiceAccount / HPA / PDB labels | **变** | **不变** |
| 内容真正变化的生成对象数 | **6 个全变** | **只有 1 个** |

补一个代码事实：**istiod 从不修改 Gateway 的 label**。它唯一写 Gateway 的地方是 `deploymentcontroller.go:779`（`setGatewayControllerVersion`），且只在从旧 controller-version 接管时写一次注解。所以上面那列 Gateway label 的变化，只可能来自你自己的 patch。

### tag 的四项实打实的好处

| 好处 | 说明 |
| --- | --- |
| **完全不动 Gateway 对象** | 翻 tag 只改 `MutatingWebhookConfiguration istio-revision-tag-<tag>` 与 `Service istiod-<tag>` 两个集群级对象；所有 Gateway / namespace / Deployment 的 label **一个字节都不变** |
| **一次翻转、原子生效** | `istioctl tag set` 改的是**同名** webhook（update，不是 delete + create），所有标了该 tag 的对象在**同一瞬间**一起切过去 |
| **回滚成本极低** | 把 tag 翻回去就回滚了。硬编码 revision 名要再全改一遍，还得记得原值 |
| **有一张显式映射表** | `istioctl tag list` 随时可查；revision 名本身没有任何登记处（虽然 `--set revision=X` 也会隐式建一个同名 tag） |

官方文档的措辞也是这个角度：

> Revision tags are stable identifiers that point to revisions and can be used to avoid relabeling namespaces… Manually relabeling namespaces when moving them to a new revision can be **tedious and error-prone**.

### 一个真实的语义差异：无人认领的中间态

tag 与 revision 名有一处**确实不同**的行为，值得单独记住。

如果你**先把 label 改成 `1-30-3`，但 1-30-3 的 istiod 还没装好或还没就绪**，那么所有 istiod 的 `IsMine` 全为 false：

- **带上配置清空 bug 的修复之后**：旧 istiod 仍发配置所以流量不挂，但 **Deployment 没人管，新 Pod 永远起不来**，直到你装好为止。
- **不修复的版本**：没有任何控制面发配置 → **立刻全挂**。

tag 流程天然避开这个状态：先装好新 revision，再翻 tag（`istioctl tag set --revision X` 还会校验 revision 存在）。换句话说，**「改 label」这个动作把「声明」和「实现」耦合在了一次操作里，顺序很容易做错。**

## 06 版本前提：旧控制面必须已带修复

上一章解释了「为什么 tag 更好」。这一章讲清那个前提 —— **它决定了第 01 章第一行的「无中断」在你的集群上能不能兑现。**

### 先记住一句话

**决定你会不会踩到配置清空 bug 的，是你当前正在跑的旧 istiod 版本，不是新装的那个。**

因为把 Gateway 从配置快照里剔除、向旧 Pod 推空 xDS 的，是**旧控制面**。新控制面修没修，救不了旧控制面正在做的事。所以判断方法是看**起始版本**：

| 起始版本（你正在跑的旧 istiod） | 含修复 | 翻 tag 升级会怎样 |
| --- | --- | --- |
| 1.28.x 及更早 | 否 | 会断 |
| 1.29.0 – 1.29.4 | 否 | 会断 |
| **1.29.5+** | **是** | 不会断 |
| 1.30.0 / 1.30.1 | 否 | **会断** |
| **1.30.2+** | **是** | **不会断** |
| **1.31.0+** | **是** | 不会断 |

实测数据点：`1.30.0 → 1.30.3` 会断，`1.30.2 → 1.30.3` 不会断 —— 差异全部来自起始版本。

### 这个 bug 是什么

**在 1.25 ~ 1.30.1 之间，只要一个 `Gateway` 的归属控制面发生变化，旧控制面会立刻把该 Gateway 从自己的配置快照里剔除，并向仍在服务的旧 gateway Pod 推送一份空 xDS 配置** —— listener 和 route 全部删除。旧 Pod 还在 Service endpoints 里继续接收 LB 流量，于是表现为**连接立即被拒**，直到新的 gateway Pod 起来，约 30 秒。

关键的一点是：**你不需要手动改 Gateway 的 label 就会触发。**

### 四条触发途径，其中三条完全不碰 Gateway

判定依据是「这个 label 值**当前解析到哪个 revision**」，而不是「label 有没有被改过」：

| 途径 | 是否碰 Gateway | 典型场景 |
| --- | --- | --- |
| ① 改 Gateway 自己的 `istio.io/rev` label | 会 | 手动把一个网关切到新 revision |
| ② 翻 Gateway 引用的 tag 的指向 | **不会** | `istioctl tag set canary --revision <新> --overwrite` |
| ③ 翻 `default` tag 的指向 | **不会** | `istioctl tag set default --revision <新>` —— 原始 issue 就是这个 |
| ④ 改 Gateway 所在 namespace 的 `istio.io/rev` label | **不会** | Gateway 自己没写 label 时会**继承 namespace 的** |

**②③④ 才是 revision 升级的正常路径。** 这也解释了为什么这个 bug 影响面这么大：在未修复的版本上，**连第 01 章推荐的那套姿势都躲不开它**。上游 issue #59959 的报告者，做的动作只有一条：

> `istioctl tag set default --revision 1-29-2 --overwrite`

他一根手指都没碰过 Gateway 对象。

再补一层：如果 Gateway 自己没写 label、所在 namespace 也没写，`selectedTag` 会是空字符串，判定落到 `myTags.Contains("default")` —— 也就是**该网关跟着 `default` revision 走**。这解释了为什么翻 `default` tag 会把一批没写 label 的网关一起搬走。

### 故障链的五个环节

**环 1 —— 一个多余且致命的过滤器。**

从 1.25 起（PR #54465，为修 #54458），`GatewayCollection()` 与 `ListenerSetCollection()` 的回调开头有：

```go
if !tagWatcher.Get(ctx).IsMine(obj.ObjectMeta) {
    return nil, nil
}
```

这**不是**「不写 status」。在 krt 里返回 nil 意味着「这个 key 没有输出」，等价于**发出 delete** —— Gateway 从整个配置快照中消失。

**环 2 —— `IsMine` 的判定方式。**

就是第 05 章那段代码。只要这个值当前解析到的不再是旧 istiod，旧 istiod 立刻 `IsMine=false`。而这个值可以来自 Gateway 自己，也可以来自它所在的 namespace；label 本身甚至可以**一个字节都没变** —— 变的是 `myTags`（它引用的 tag 被翻走了）。

**环 3 —— 旧 Pod 无法「漂移」过去。**

gateway Pod 的 `CA_ADDR` 是**硬编码在 Pod spec 里**的，旧 Pod 一生只连 `istiod-1-28-6`，label 改了它也不会自动切到新控制面。

**环 4 —— 空推，而流量还在（真正的断点）。**

旧 istiod 把 Gateway 丢掉 → 给仍在连它的旧 gateway Pod 推送**空 xDS**（listener / route 全删）。而旧 Pod 依然在 Service endpoints 里继续接收 LB 流量 → 表现为连接被拒。

**环 5 —— 新 Pod 需要 20~30 秒。**

新 istiod 要接管 webhook、改写 Deployment、滚出新 Pod，新 Pod 还要过 startupProbe（最长 30×1s）与 readinessProbe（15s 周期）。这段窗口里**没有任何 Pod 能服务**。

两条通道的状态是错位的：

```text
同一瞬间，两条通道状态错位：

旧 Pod ──▶ istiod-1-28-6 ──▶ 推空 xDS，立刻断供   ×
新 Pod ──▶ istiod-1-29-2 ──▶ 配置完整，20~30s 才就绪

旧通道断了，新通道还没建好 —— 这就是那 30 秒。
```

> 关键认知：这不是「滚动更新造成的」，而是「**旧控制面把配置清空**」×「**新 Pod 还没就绪**」的叠加。滚动更新本身有 startupProbe / readinessProbe 保护，是安全的。

### 一个常见的误判方向

issue 里有人说「被清空的是 HTTPRoute 的 status」，并把线索指向 PR #58292。但 #58292 只改 **status 写入**（在 `pilot/pkg/status/collections.go` 的 `RegisterStatus` 里加 `IsMine` 过滤），**完全不碰 xDS 配置生成**。

status 变空只是同一个根因的旁证 —— Gateway 被丢掉后，route 找不到 parent，于是 status 也空了。**顺着 status 这条线查会走偏。**

### 为什么不用 revision 的集群没事

不用 revision 时，配置过滤走 `LabelsInRevision`，而**没有 label 的对象是 global object**（第 02 章那段代码），所有 istiod 都会生成配置。这也解释了 issue 里报告者的另一个观察：不用 revision、纯 `istioctl install -f values.yaml` 跨版本升级**反而一切正常**。

### 修复：删掉那个过滤器

修复非常干脆 —— 直接**删掉** config-emission 层的 `IsMine` 过滤，因为它在另外两处已经是冗余的：

| 关注点 | 过滤器位置 | 修复后 |
| --- | --- | --- |
| **配置生成**（listener / route） | `gateway_collection.go` | **删除** —— 所有 revision 都为自己的 Pod 生成配置 |
| **status 写入** | `pilot/pkg/status/collections.go` `RegisterStatus` | **保留** —— 只有 owner 写，避免多控制面互相覆盖 |
| **Deployment 管理** | `gatewaycommon/deploymentcontroller.go:356` | **保留** —— 只有 owner 管，避免重复接管 |

修复代码自己的注释，比 release note 写得清楚：

```go
// pilot/pkg/config/kube/gateway/gateway_collection.go · ListenerSetCollection
//
// Note: tagWatcher.IsMine() is intentionally not filtered at this config-emission layer. Filtering
// here caused a temporary outage when a Gateway's or ListenerSet's istio.io/rev label was changed:
// the prior owning control plane immediately dropped the resource and pushed empty xDS config to
// pods still running on the old revision (see https://github.com/istio/istio/issues/59959).
```

### 被否决的替代方案

另一条路线是在提前返回之前调用 `ctx.DiscardResult()`，让 krt 保留上一次的输出而不是发 delete：

```diff
  if !tagWatcher.Get(ctx).IsMine(obj.ObjectMeta) {
+     ctx.DiscardResult()
      return nil, nil
  }
```

维护者 howardjohn 的两条否决理由，恰好解释了为什么最终方案是「删掉」而不是「打补丁」：

> 我们改了一条代码路径，但可能还有 100 条路径对 revision 有隐性依赖并会生成错误配置，很难确信补全了所有正确的地方。
>
> 这个方案依赖存在 last known config。想象一个新起的 istiod 副本 —— 我们又会回到坏配置的状态。

这个 PR（#59583）于 2026-05-09 被 stale bot 关闭，**从未合并**。

### 还有一半没修：HTTPRoute

`pilot/pkg/config/kube/gateway/controller.go:494` 的 `buildClient()`：

```go
filter := kclient.Filter{
    ObjectFilter: kubetypes.ComposeFilters(kc.ObjectFilter(), c.inRevision),
}
// all other types are filtered by revision, but for gateways we need to select tags as well
if res == gvr.KubernetesGateway {          // ← 只有这一个 GVR 被豁免
    filter.ObjectFilter = kc.ObjectFilter()
}
```

看调用点（`controller.go:213-235`）：Gateways 被豁免，但 **HTTPRoutes / GRPCRoutes / TLSRoutes / TCPRoutes / BackendTLSPolicies / ListenerSets 全都没有**。而 `LabelsInRevision` 只在对象**没有** label 时才返回 true：

| HTTPRoute 上的 label | 老 istiod 的 informer | 结果 |
| --- | --- | --- |
| 不带 `istio.io/rev` | 看得见 | 安全 |
| 带了 `istio.io/rev: 1-28-6` | **根本没有这条 route** | **同类中断** |

修它需要豁免所有 route GVR，对应 PR **#59565 被关闭、未合并**。所以 issue #58840 至今只修了一半。

> HTTPRoute 不要打 `istio.io/rev`。这是目前唯一仍未修复的坑。

## 07 为什么直接改 revision 名会断 30 秒

第 06 章的 bug 在修复版本上不复现了。但**即使两侧控制面都已修复，改 Gateway 的 revision 名这条路依然会断 30 秒** —— 这是另一条完全独立的机制，也是「只写 tag」为什么是硬性要求的直接答案。

### 一个令人困惑的实验结果

环境是多 revision 并存多个 istiod（1.30.0 / 1.30.2 / 1.30.3），ingress 使用 Kubernetes Gateway API 的 `Gateway` 资源 + istio 的 `GatewayClass`。观测手段是 Gateway 前面挂 LB，循环 curl 打 LB 地址，记录失败窗口：

| | 写 revision 名（patch label） | 写 tag（翻 tag） |
| --- | --- | --- |
| Gateway 的 `istio.io/rev` | `1.30.0` → patch 成 `1.30.2` → patch 成 `1.30.3` | 恒为 `stable`，整个生命周期不变 |
| 切换动作 | `kubectl patch` Gateway label | `istioctl tag set stable --revision ...` |
| 1.30.0 → 1.30.2 | 约 30s 中断 | — |
| **1.30.2 → 1.30.3** | **约 30s 中断** | **无中断** |

最后一行是问题所在。`1.30.2 → 1.30.3` 两侧的 istiod **都已经带了第 06 章的修复**，所以「旧控制面把 Gateway 剔除、推空 xDS」这个根因**在这一步并不成立** —— 中断另有来源。

两种方式的共同现象是：Gateway 对应的 Deployment 都**正常滚动**，新 Pod 也能正常起来。差异在于 patch label 这条路在滚动窗口内有约 30 秒的连续失败。关键特征是「**新 Pod 是好的，老 Pod 也没崩，但流量就是断的**」。

### 差异集合只有 4 项

两种方式下 pod template 都会变（`CA_ADDR` 那段），所以差别不在「滚不滚」。把 patch label 独有的写入逐个拿出来判断：

| 只有 patch label 会发生的写入 | 能否直接作用于连接 | 判断 |
| --- | --- | --- |
| Gateway 对象本身被改写 | 唤醒集群里所有 Gateway watcher。istio 自身**不会**因此断流（配置已不分 revision） | 放大器，不是直接原因 |
| **Service（LoadBalancer）metadata.labels 被改写** | **会** —— 它是流量入口对象，是唯一被改写的入口资源 | **首要嫌疑** |
| Pod template 的 `istio.io/rev` label 从 `1.30.2` 变 `1.30.3` | 只有当集群里有东西**以该 label 为选择器**时才会（NetworkPolicy / 自研 controller / 监控抓取规则）。istio 自身不按它选 Pod | 需要自查 |
| ServiceAccount / HPA / PDB 的 metadata.labels 被改写 | 无直接影响 | 排除 |

### 30s 这个数字本身也是线索

它同时吻合 `startupProbe` 的预算（30×1s）与 `terminationGracePeriodSeconds` 的 k8s 默认值 30s。所以更可能的形态是「**入口对象被改写**」与「**Pod 滚动**」**两个窗口叠加**，而不是某个单一对象。

### 必须诚实标注的置信度

这部分结论分两档，写清楚比写好看重要。

**已确定（代码直读）**：写入集合的差异。patch label 真实改写 6 个对象，翻 tag 只改写 1 个。

**未确定**：Service 的 metadata 改写是否就是那 30 秒的**直接原因**。metadata-only 的 Service 更新对多数 LB 控制器（含 AWS CCM）是 no-op —— 单靠它解释 30 秒**偏弱**，需要实测。

### 两个可以自己跑的决定性实验

**实验一：把 label 复制链关掉。**

既然差异已经定位到这条复制链，就直接把它切断：

```bash
# 给 istiod 加环境变量后重启
# helm 等价于 --set pilot.env.PILOT_ENABLE_GATEWAY_API_COPY_LABELS_ANNOTATIONS=false
PILOT_ENABLE_GATEWAY_API_COPY_LABELS_ANNOTATIONS=false

# 然后原样重跑：patch gateway label 1.30.2 → 1.30.3
```

- **中断消失** → 机制确定，就是这条复制链。再往下缩一环：
  - 看 LB 侧：`kubectl -n <ns> get svc <gw>-istio -w`，观察 EXTERNAL-IP / 端口是否瞬闪
  - 看有没有东西按 `istio.io/rev` 选 Pod：

```bash
kubectl get networkpolicy,pdb -A -o json \
  | jq '.. | objects | select(.matchLabels?) | .matchLabels | select(has("istio.io/rev"))'
```

- **中断还在** → 这条链被证伪，做实验二。

**实验二：确认翻 tag 那一路里 gateway 有没有真的迁移过去。**

因为两种方式下 pod template 都该变，若翻 tag 后 Deployment 根本没滚，那「无中断」只是「什么都没发生」：

```bash
NS=<ns>; GW=<gateway-name>
kubectl -n "$NS" get deploy "$GW-istio" -o jsonpath=\
'{.metadata.generation}{"  "}{.spec.template.spec.containers[?(@.name=="istio-proxy")].image}{"\n"}{.spec.template.spec.containers[?(@.name=="istio-proxy")].env[?(@.name=="CA_ADDR")].value}{"\n"}'

istioctl proxy-status | grep "$GW"     # 最后一列应指向 istiod-1.30.3-xxx
```

如果 `CA_ADDR` / proxy-status 仍停在 `istiod-1.30.2`，则翻 tag 的对比前提不成立，需要重做。

## 08 零停机升级清单

把前面所有结论收敛成一份可以直接照着做的流程：

1. **先确认旧控制面版本。** 起始版本必须 ≥ 1.29.5 / 1.30.2 / 1.31.0。这是第 06 章的前提，也是唯一一个「做不到就没法零停机」的硬条件 —— 如果旧版本更低，**先升到修复版本，再做后续步骤**。
2. **装新 revision，并确认就绪。** `istioctl install --set revision=1-30-3`，等到 `istiod-1-30-3` 全部 Ready 再进入下一步。
3. **Gateway 的 `istio.io/rev` 只写 tag，永不写具体 revision 名。** 例如固定写 `canary`，让这个值在整个生命周期内不变。
4. **翻 tag 完成切换。** `istioctl tag set canary --revision 1-30-3 --overwrite` —— 一次原子切换，Gateway CR 完全不动。之后 gateway Deployment 会自动滚动，这是预期行为。
5. **HTTPRoute 不要打 `istio.io/rev`。** 这是目前唯一仍未修复的坑。
6. **给 gateway Deployment 足够的安全边际。** 至少 2 副本 + PodDisruptionBudget + `strategy.rollingUpdate.maxUnavailable: 0`。

### 排障命令

```bash
# 1. 确认所有控制面版本（重点看 istiod，不是 client）
istioctl version

# 2. 确认待升级对象的 revision 名真实存在
istioctl tag list
kubectl get mutatingwebhookconfiguration -l istio.io/tag

# 3. 确认 route 上有没有 revision label（第 06 章的残留那一半）
kubectl get httproute,grpcroute,tcproute,tlsroute -A -o json \
  | jq '.items[] | select(.metadata.labels["istio.io/rev"]) | .metadata'

# 4. 看副本数与滚动策略
kubectl -n <ns> get deploy <gw> -o jsonpath='{.spec.replicas}{"\n"}{.spec.strategy}{"\n"}'

# 5. 滚动期间盯 endpoints 会不会掉到 0
kubectl -n <ns> get endpoints <gw> -w
```

### 场景速查：到底该选哪种

| 场景 | 建议 |
| --- | --- |
| 生产、不能接受中断 | **Revision + tag** |
| 需要跨 2 个 minor 升级 | 只能用 revision |
| 需要灰度验证新控制面 | 只能用 revision |
| 单节点 / 开发集群 / 资源紧张 | In-place 可以接受，但要配 ≥2 istiod 副本 + PDB |
| 想省事、一次升完 | In-place，但避开业务高峰 |
| Gateway API 网关 + 零停机 | Revision + tag，且 Gateway 的 `istio.io/rev` 只写 tag |

## 09 版本速查与结论边界

### 一张表自查你的集群

起始版本（**你正在跑的旧 istiod**）与 #59959 修复的对照 —— 经 GitHub compare API 做 **commit ancestry 校验**，不是只读 release note 文本：

| 起始版本区间 | 含修复 | PR / commit |
| --- | --- | --- |
| 1.28.x 及更早 | 否 | 未 backport |
| 1.29.0 – 1.29.4 | 否 | — |
| **1.29.5+** | **是** | #60627 · `17c24702` |
| 1.30.0 / 1.30.1 | 否 | — |
| **1.30.2+** | **是** | #60624 · `9076b316` |
| **1.31.0+** | **是** | #60158 · `4e5bcf3f`（master 继承） |

注意两件事：

- 这张表看的是**起始版本**，不是目标版本。`1.30.0 → 1.30.3` 会断，`1.30.2 → 1.30.3` 不会断。
- `1.30.2 → 1.30.3` 这类**两侧都已修复**的升级，如果走的是「改 Gateway 的 revision 名」这条路，仍然可能有约 30 秒中断 —— 那是第 07 章的机制，与版本无关。

### 结论边界

写技术笔记最忌讳把推断当结论，所以明确标一下这篇的可信度分层。

**已确定（代码直读 + commit ancestry 校验）**

- 配置清空 Bug 的根因、修复方式、落入版本
- `IsMine` 对 tag 名与 revision 名一视同仁
- `CA_ADDR` 取 owner istiod 自己的 revision，tag 从不进入 Pod spec
- `EnableGatewayAPICopyLabelsAnnotations` 默认 true，导致 Gateway 的 label 被复制到 6 个生成对象
- patch label 改写 6 个对象、翻 tag 只改写 1 个

**尚未验证（按可能性排序的候选）**

- 那 30 秒的**直接原因**是哪一次写入。首要嫌疑是 LoadBalancer Service 的 metadata 被改写，但 metadata-only 的 Service 更新对多数 LB 控制器是 no-op，需要实测。

### 参考资料

- [Issue #59959](https://github.com/istio/istio/issues/59959) · [PR #60158](https://github.com/istio/istio/pull/60158) · [PR #60624](https://github.com/istio/istio/pull/60624) · [PR #60627](https://github.com/istio/istio/pull/60627)
- [PR #59583（已关闭）](https://github.com/istio/istio/pull/59583) · [PR #59565（已关闭）](https://github.com/istio/istio/pull/59565) · [Issue #58840](https://github.com/istio/istio/issues/58840)
- [Canary Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/canary/) · [In-place Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/in-place/) · [Upgrading gateways · istio.io](https://istio.io/latest/docs/setup/additional_setup/gateway/#upgrading-gateways)

## 写在最后

回顾整篇，三个最值得记住的判断：

第一，**revision 升级只有一种姿势是对的：Gateway 永远写 tag，升级时只翻 tag 的指向**。翻 tag 之后 Deployment 会自动滚动，这是预期行为，而且是干净的 —— 因为除了 pod template，没有任何对象被改写。

第二，**「只写 tag」不是风格偏好，是硬性的**。写 revision 名会让 6 个生成对象被改写（含 LoadBalancer Service），写 tag 只改写 1 个。这不是 6 倍的书写量，是 6 倍的爆炸半径。

第三，**这套姿势有一个版本前提**：旧控制面必须已经带上 #59959 的修复（起始版本 ≥ 1.29.5 / 1.30.2 / 1.31.0）。1.25 ~ 1.30.1 上，连翻 tag 都会把 Gateway 配置清空。**升级前先确认旧版本，比什么都重要。**

---

> 我是 {{作者名}}，{{一句话简介}}。如果你觉得今天这篇有收获，欢迎**点赞、在看、转发**三连，我们下篇见。
