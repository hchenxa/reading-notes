# Istio 学习笔记

> 资料核对日期:2026-09-27。源码基准 `istio/istio@9c8ba31`(master,sparse clone),
> 版本判断经 GitHub compare API 做 **commit ancestry 校验**,不是只读 release note 文本。
> 建议顺序:先看下面的速览 → 遇到升级中断看第 2 篇 → 想搞清楚那个 bug 看第 1 篇 →
> 要决定用哪种升级方式看第 3 篇。

## 0. 一分钟速览

- **1.25 ~ 1.30.1 有一个会把 Gateway 配置清空的 bug**:只要一个 `Gateway` 的**归属控制面变了**
  (翻 tag、改 namespace label、改 Gateway 自己的 label,三条都算),旧控制面立刻把该 Gateway
  从配置快照里剔除,向仍在服务的旧 gateway Pod 推**空 xDS**。
  **正常 revision 升级走的翻 tag 路径就会踩到 —— 你不需要手动改 Gateway 的 label。**
  修复在 1.29.5 / 1.30.2 / 1.31.0。
- **tag 与 revision 名只在「所有权判定」上等价**,两个操作本身**不等价** —— patch label 会连锁
  改写 **6 个**生成对象(含 LoadBalancer Service),翻 tag 只改写 **1 个**(Deployment 的 pod template)。
  见第 2 篇。
- **in-place 升级的中断来源是 istiod 可用性**(注入 webhook fail-closed、CA 断供、endpoint 推不下去),
  与上面那个配置清空 bug 是**两件独立的事**,不要混为一谈。见第 3 篇。
- **还有一半没修**:打了 `istio.io/rev` label 的 HTTPRoute 仍然被 informer 级过滤,
  对应修复 PR #59565 已关闭未合并。

## 1. 文档索引

| 文档 | 讲什么 | 什么时候看 |
| --- | --- | --- |
| [Gateway 配置清空 Bug](Gateway配置清空Bug.md) | #59959 的根因、故障链、修复方案、被否决的替代方案、版本矩阵 | 想理解"为什么改个 label 就断 30 秒"的原理;或要判断自己的版本有没有修 |
| [升级中断排查](升级中断排查.md) | patch label 与翻 tag 为什么结果不同:两组对比实验、两种操作的写入对象集合、决定性实验 | **正在排障**;或要决定 Gateway 的升级姿势 |
| [In-place 与 Revision 升级](In-place与Revision升级.md) | 两种升级方式各是什么、怎么用、怎么选,以及两套完全不同的风险来源 | 要做升级方案选型;或想知道 `istioctl upgrade` 到底做了什么 |

## 2. 版本速查

Gateway 配置清空 Bug 的修复状态(经 commit ancestry 校验):

| 版本区间 | 含修复 | PR / commit |
| --- | --- | --- |
| 1.28.x 及更早 | ❌ | 未 backport |
| 1.29.0 – 1.29.4 | ❌ | — |
| **1.29.5+** | ✅ | #60627 · `17c24702` |
| 1.30.0 / 1.30.1 | ❌ | — |
| **1.30.2+** | ✅ | #60624 · `9076b316` |
| **1.31.0+** | ✅ | #60158 · `4e5bcf3f`(master 继承) |

> 注意:`1.30.2 → 1.30.3` 这类**两侧都已修复**的升级,仍然可能有约 30 秒中断 ——
> 那是另一个机制,见 [升级中断排查](升级中断排查.md)。

## 3. 本目录的结论边界

写笔记时最忌讳把推断当结论,所以明确标一下:

**已确定(代码直读 + commit ancestry 校验)**

- 配置清空 Bug 的根因、修复方式、落入版本
- `IsMine` 对 tag 名与 revision 名一视同仁
- `CA_ADDR` 取 owner istiod 自己的 revision,tag 从不进入 Pod spec
- `EnableGatewayAPICopyLabelsAnnotations` 默认 true,导致 Gateway 的 label 被复制到 6 个生成对象
- patch label 改写 6 个对象、翻 tag 只改写 1 个

**尚未验证(按可能性排序的候选)**

- 那 30 秒的**直接原因**是哪一次写入。首要嫌疑是 LoadBalancer Service 的 metadata 被改写,
  但 metadata-only 的 Service 更新对多数 LB 控制器是 no-op,需实测。
  → 实验方法见 [升级中断排查 §4](升级中断排查.md)

## 4. 参考资料

- [Issue #59959](https://github.com/istio/istio/issues/59959) ·
  [PR #60158](https://github.com/istio/istio/pull/60158) ·
  [PR #60624](https://github.com/istio/istio/pull/60624) ·
  [PR #60627](https://github.com/istio/istio/pull/60627)
- [Canary Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/canary/) ·
  [In-place Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/in-place/) ·
  [Upgrading gateways · istio.io](https://istio.io/latest/docs/setup/additional-setup/gateway/#upgrading-gateways)

---

> 本地调试用的 istio 源码 sparse clone 存放在 `/tmp/istio-src`(重启会丢,需要时重新 clone)。
