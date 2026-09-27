# Istio 升级方式:In-place 与 Revision 的使用与区别

> 资料核对日期:2026-09-27。命令与约束对照 istio.io 官方 `In-place Upgrades` 与
> `Canary Upgrades` 文档,机制部分对照 `istio/istio@9c8ba31` 源码。
> Gateway 相关的升级中断另见 [升级中断排查](升级中断排查.md)。

## 0. 一页速览

| | **In-place 升级** | **Revision(canary)升级** |
| --- | --- | --- |
| 心智模型 | 把现有控制面**原地换掉** | **新旧控制面并存**,把流量一批批切过去 |
| 命令 | `istioctl upgrade` | `istioctl install --set revision=<新>` + 改 label/tag + `istioctl uninstall --revision=<旧>` |
| 官方态度 | "Traffic disruption may occur" | **"much safer than doing an in-place upgrade and is the recommended upgrade method"** |
| 跨版本幅度 | 只能逐个 minor(1.29→1.30→1.31) | **允许跨 2 个 minor** |
| 回滚 | 只能再做一次 in-place 降级,且要换对应版本的 `istioctl` | 把 label/tag 切回去即可 |
| 主要风险 | **istiod 可用性** | **所有权切换时的配置连续性** |

**一句话选型**:生产环境默认用 **revision**;只有当集群很小、不方便维护多份控制面、
且能接受升级窗口时,才用 in-place。

> ⚠️ 两者不通用:`istioctl upgrade` **不支持**用 `--revision` 安装出来的控制面,
> 会直接报错。用哪种装的,就只能用哪种升。

## 1. In-place 升级

### 1.1 是什么

`istioctl upgrade` 把已安装的 Istio **原地**换到新版本 —— 控制面和 gateway 一起被替换,
集群里始终只有**一份**控制面。

### 1.2 怎么用

```bash
# 1. 用新版本的 istioctl(在下载包的 bin/ 下)
cd istio-<新版本>/

# 2. 确认 kubectl 指向正确的集群
kubectl config view

# 3. 前置检查
istioctl x precheck

# 4. 执行升级
#    如果原来是用 -f 装的,必须传同样的 -f;用 --set 装的,必须传同样的 --set,
#    否则自定义配置会被还原成默认 profile。
istioctl upgrade -f <原来那份配置>

# 5. 升级完成后,手动滚动数据面
kubectl rollout restart deployment -n <你的业务命名空间>
```

### 1.3 前置约束

- **已安装版本不能比目标版本低超过一个 minor**。例如升到 1.31,当前必须是 1.30.x。
- 必须是**用 `istioctl` 装的**(`istioctl install` / `istioctl upgrade` 那条路径)。
- 用 `--revision` 装的集群**不适用**,会报错。
- 升级要复用原来的 `-f` / `--set`;生产环境建议用配置文件而不是 `--set`,避免遗忘。

### 1.4 为什么会有 downtime

官方文档只有一句警告,但机制值得展开:

> **Warning**: Traffic disruption may occur during the upgrade process. To minimize the
> disruption, ensure that **at least two replicas of `istiod`** are running. Also, ensure that
> **PodDisruptionBudgets** are configured with a minimum availability of 1.
>
> …`istioctl` will in-place upgrade the Istio control plane **and gateways** to the new version.

**核心:in-place 没有第二个控制面兜底。** revision 升级时新老 istiod 并存,老的持续服务老 Pod;
in-place 时 istiod 自己先被滚掉,没有任何 fallback。由此产生四个后果:

| 后果 | 机制 |
| --- | --- |
| **注入 webhook fail-closed** | `istio-sidecar-injector` 的 `failurePolicy: Fail`。istiod 全挂时**新 Pod 根本创建不出来** —— 升级期间做任何 rollout 都会卡住。这是最常见的事故形态 |
| **CA / SDS 断供** | istiod 就是 CA。证书轮转失败;若正好有 workload 证书在这个窗口到期,mTLS 直接断 |
| **新 endpoint 推不下去** | 窗口内上线的 Pod 不会及时进入其他 Envoy 的 cluster —— 后端已经扩容,流量却过不去 |
| **已有 Envoy 不会清空配置** | xDS 断连时 Envoy 保留最后一份可用配置,所以**存量流量通常还在**。这正是 in-place 往往"看起来没事"的原因 |

另外两点结构性劣势:

- **不可回滚**。出问题只能再 in-place 降级,还得换对应版本的 `istioctl`,暴露窗口翻倍。
- **gateway 也在原地被升**。`istioctl upgrade` 会把 gateway Deployment 一起滚。没有第二份
  gateway 可以分流时,这个滚动窗口就是纯 downtime。

### 1.5 单控制面为什么"看起来没事"

一个常见反直觉现象:不用 revision、纯 `istioctl install -f values.yaml` 跨版本升级,
**反而一切正常**。原因是配置过滤走 `LabelsInRevision`,而**没有 label 的对象是 global object**:

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

所有 istiod 都会生成配置,不存在"旧控制面清空配置"的问题。
**所以 in-place 的风险是 istiod 可用性,不是配置连续性** —— 这两件事不要混。

### 1.6 降级

`istioctl upgrade` 也能降级,步骤与升级完全一致,只是要换成**目标版本的 `istioctl` 二进制**:

- 前置:已安装版本不能比目标版本高超过一个 minor
- 必须用目标版本的 istioctl(例如从 1.7 降到 1.6.5,就用 1.6.5 的 istioctl)
- 也可以用 `istioctl install` 装一个更老的控制面来达到同样效果

## 2. Revision(canary)升级

### 2.1 是什么

用 `revision` 安装参数,在同一集群里**并存多份完整、互相独立的控制面**。每份 revision
有自己的 `Deployment`、`Service`、注入 webhook。

> "Each revision is a full Istio control plane implementation with its own `Deployment`, `Service`, etc."

升级 = 装一份新的 revision,把工作负载一批批切过去,最后删掉旧的。

### 2.2 怎么用

```bash
# 0. 前置检查(推荐)
istioctl x precheck

# 1. 装新 revision —— 老控制面完全不受影响
istioctl install --set revision=1-31-0

#    装完可以看到两份并存:
kubectl get pods -n istio-system -l app=istiod
#    istiod-1-30-2-xxx   1/1   Running
#    istiod-1-31-0-yyy   1/1   Running

# 2. 把工作负载迁到新 revision(见 §2.3)

# 3. 确认没有工作负载还在用旧 revision 后,删掉旧控制面
istioctl uninstall --revision 1-30-2 -y
```

> 卸载只会删掉指定 revision 的资源,**不会**删掉与其他控制面共享的集群级资源。

### 2.3 数据面怎么迁 —— 两种方式

**(a) 直接标 revision(简单,但对象多时难维护)**

```bash
# 注意:istio-injection 优先级高于 istio.io/rev,必须先删掉它,否则不会生效
kubectl label namespace <ns> istio-injection-
kubectl label namespace <ns> istio.io/rev=1-31-0 --overwrite

# 然后重启 Pod 触发重新注入
kubectl rollout restart deployment -n <ns>
```

**(b) 用 revision tag(推荐)**

tag 是**稳定别名**,指向某个 revision。好处是升级时不用改任何对象的 label,
只翻 tag 的指向:

```bash
# 建立 tag
istioctl tag set prod-stable --revision 1-30-2
istioctl tag set prod-canary --revision 1-31-0

# 查看映射
istioctl tag list

# namespace / Gateway 上写的是 tag 名,而不是 revision 名
kubectl label namespace <ns> istio.io/rev=prod-stable --overwrite

# —— 之后要升级到 1-31-0,只改 tag 指向 ——
istioctl tag set prod-stable --revision 1-31-0 --overwrite
# 再重启工作负载
kubectl rollout restart deployment -n <ns>
```

> "Notice that no relabeling was required to migrate workloads to the new revision."

**tag 的额外价值**(详见 [升级中断排查](升级中断排查.md)):
`istioctl tag set` 改的是**同名** webhook(update 而非 delete + create),所有标了该 tag 的
对象在**同一瞬间**一起切过去;而且它**完全不触碰**你的 Gateway / namespace / Deployment 对象,
因此不会连锁改写这些对象生成的资源的 metadata。

**`default` tag 的特殊语义**:tag `default` 指向的 revision 是"默认 revision",额外承担:

- 为 `istio-injection=enabled`、`sidecar.istio.io/inject=true`、`istio.io/rev=default` 注入 sidecar
- 校验 Istio 资源
- **抢占非默认 revision 的 leader 锁**,执行单例 mesh 职责

### 2.4 迁移顺序与回滚注意

- 迁移是**逐个 namespace / 逐个 Gateway** 做的,可以随时停下来观察。
- **回滚**:把 label 或 tag 切回旧 revision 即可,代价远低于 in-place。
- ⚠️ **如果之前对 gateway 做过 in-place 升级**(比如用 `default` profile 装了 revision 化的
  gateway),`istioctl uninstall` **不会**自动把它恢复成旧 revision 的 gateway。
  需要手工用**对应旧版本的 `istioctl`** 把旧 gateway 装回来。
  官方提示:为避免 downtime,**先确认旧 gateway 已经跑起来,再进行 canary 卸载**。

## 3. 对比

### 3.1 逐项对比

| 维度 | In-place | Revision / canary |
| --- | --- | --- |
| 控制面数量 | 只有一份,被滚掉时无兜底 | 新旧并存,旧的一直在服务 |
| 安装方式 | `istioctl install` / `istioctl upgrade` | `istioctl install --set revision=<值>` |
| 升级命令 | `istioctl upgrade` | 装新 revision → 切 label/tag → 卸旧 revision |
| 跨版本幅度 | 只能逐个 minor | **允许跨 2 个 minor** |
| 前置检查 | `istioctl x precheck` | `istioctl x precheck` |
| 灰度能力 | 无(一次全切) | 有(namespace / Gateway 粒度) |
| 回滚 | 再做一次 in-place 降级 + 换 istioctl 版本 | 切回 label / tag |
| 数据面 | 升级完**手动** `kubectl rollout restart` | 迁 namespace 后 `rollout restart` |
| 主要风险 | istiod 可用性(见 §1.4) | 所有权切换时的配置连续性 |
| 资源开销 | 小 | 并存期间约 2 倍控制面资源 |

### 3.2 Gateway 在两种方式下的行为差异

这是很容易踩坑的地方。官方文档明确区分:

> Refer to [Gateway Canary Upgrade] to understand how to run revision specific instances of Istio gateway.
> In this example, since we use the `default` profile, Istio gateways do **not** run revision-specific
> instances, but are instead **in-place upgraded** to use the new control plane revision.

- **`default` profile 装的 gateway**:不带 revision,跟着控制面**原地升级**。
- **要跑 revision 专属的 gateway**:需要另外建一份带 `istio.io/rev` 的 Deployment。
  注意文档的一个限制:

  > Because other installation methods bundle the gateway `Service` … with the gateway `Deployment`,
  > only the Kubernetes YAML method is supported for this upgrade method.

- **Gateway API 的 `Gateway` 资源**:由 istiod 托管 Deployment,情况又不同 ——
  它的升级中断机制、以及 patch label 与翻 tag 的差异,见 [升级中断排查](升级中断排查.md)。

### 3.3 怎么选

| 场景 | 建议 |
| --- | --- |
| 生产、不能接受中断 | **Revision + tag** |
| 需要跨 2 个 minor 升级 | 只能用 revision |
| 需要灰度验证新控制面 | 只能用 revision |
| 单节点 / 开发集群 / 资源紧张 | In-place 可以接受,但要配 ≥2 istiod 副本 + PDB |
| 想省事、一次升完 | In-place,但避开业务高峰 |
| Gateway API 网关 + 零停机 | Revision + tag,且 Gateway 的 `istio.io/rev` 只写 tag |

## 4. 两者的 downtime 来源完全不同

这是最值得记住的一点 —— 两种方式都会中断,但**原因不一样,排查方向也不一样**:

| | In-place | Revision |
| --- | --- | --- |
| 中断来源 | **istiod 不可用**(注入 webhook fail-closed、CA 断供、endpoint 推不下去) | **所有权切换时的配置连续性** |
| 为什么 | 没有第二个控制面兜底 | 新旧控制面交接时,配置和 Deployment 的归属要转移 |
| 排查起点 | istiod 副本数、PDB、升级窗口内的 Pod 创建失败事件 | 归属切换时"哪些对象被改写了"、旧 Pod 是否还拿得到配置 |
| 参考 | §1.4 | [升级中断排查](升级中断排查.md) |

另外,**Gateway 配置清空 Bug**(1.25 ~ 1.30.1)是 revision 路径上一个独立的、已被修复的
第三类问题,见 [Gateway 配置清空 Bug](Gateway配置清空Bug.md)。

## 5. 相关文档

- [Gateway 配置清空 Bug](Gateway配置清空Bug.md) —— #59959 的根因与修复
- [升级中断排查](升级中断排查.md) —— patch label 与翻 tag 为什么不同

## 6. 参考资料

- [In-place Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/in-place/)
- [Canary Upgrades · istio.io](https://istio.io/latest/docs/setup/upgrade/canary/)
- [Upgrading gateways · istio.io](https://istio.io/latest/docs/setup/additional-setup/gateway/#upgrading-gateways)
