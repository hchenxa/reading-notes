# Kubernetes Gateway API 详解:从概念到字段级使用

> 资料核对日期:2026-09-05,以 **Gateway API v1.6.2**(2026-09-03 发布,Standard channel)为准,
> 字段级内容均逐条对照官方源码 `apis/v1/*.go` 与 `config/crd/standard`(v1.6.2 tag)、官网
> api-types/spec 页面、各版 release notes 与官方博客。Gateway API 演进很快(Standard 目标约 4 个月
> 一发),用前请再核对 [gateway-api.sigs.k8s.io](https://gateway-api.sigs.k8s.io) 与你所选实现的文档。
>
> 建议顺序:① 概念 → ② 装起来跑通(0/1/13 节)→ ③ 啃字段(GatewayClass/Gateway → HTTPRoute →
> 其余 xRoute/策略)→ ④ 迁移与排障按需查。

## 0. 一分钟速览

- Gateway API 是 Kubernetes 的下一代流量管理 API,**取代 Ingress 的定位**,但远比 Ingress 大:
  它是一个对象家族(10 个 GA 资源),把"入口/路由/策略/跨命名空间授权"拆成独立对象,天然支持
  **多团队、多租户、共享网关**。
- 核心一句话:**GatewayClass 选实现 → Gateway 开"门" → 路由(HTTPRoute 等)决定"门"里流量去哪 → 策略挂件加能力 → ReferenceGrant 放行跨命名空间引用**。
- 当前(2026-09)Standard/GA 资源:GatewayClass、Gateway、**HTTPRoute**、GRPCRoute、TLSRoute、
  TCPRoute、UDPRoute、**ListenerSet**、**BackendTLSPolicy**、**ReferenceGrant**,一律
  `apiVersion: gateway.networking.k8s.io/v1`(实验资源在 `gateway.networking.x-k8s.io/v1alpha1`,
  名字带 `X` 前缀)。
- 仍处 Experimental 的重要特性:HTTPRoute 上的 **retry**(HTTPRoute 级)/**sessionPersistence**、
  ExternalAuth、Default Gateways、XBackendTrafficPolicy、XBackend、XMesh 等(见 §4.3)。

```bash
# 安装官方 CRD(standard 通道,建议用 --server-side;v1.5.1 起实验 CRD 过大,普通 apply 会失败)
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/standard-install.yaml
# 想用实验特性(有 X 前缀资源 + 实验字段)再装:
# kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.2/experimental-install.yaml
# 注意:standard 与 experimental CRD 不能互相覆盖(有 safe-upgrades VAP 守护)
```

## 1. 为什么需要 Gateway API:Ingress 的四个天花板

Ingress(v1,2017 至今)做 HTTP(S) 入口做了很多年,但它是"**单资源、单控制器、annotation 扩展**"
的模型,四个问题很难绕:

| 问题 | Ingress 的表现 | Gateway API 的做法 |
| --- | --- | --- |
| **单一角色** | 只有一个"用户"视图,集群管理员/平台团队/应用团队挤在一起,无法表达"谁可以开监听端口" | **四个显式角色 + RBAC 对齐**:**基础设施提供方**(建 GatewayClass,实现方)、**集群操作员**(建 Gateway,开端口/配证书)、**应用管理员**(建 Route,管流量策略)、**应用开发者**(只写 workload)。每层的操作范围天然收敛 |
| **共享与多租户差** | 每个 Ingress 自己声明 host/path 规则,多团队共用一个 LB 时靠控制器自定合并规则,冲突处理不透明 | **Gateway 是显式共享点**:谁的路由能挂到我的监听器,由 `allowedRoutes` 声明;规则合并优先级写进规范(§7.7) |
| **可移植性差** | 高级能力全靠 `nginx.ingress.kubernetes.io/xxx` 这类注解,注解是方言,换实现等于重写 | 高级能力**结构化**进 spec(filters、weight、timeouts…),Core 行为跨实现一致;实现差异收敛到明确的 Extension 点(extensionRef/自定义策略) |
| **只覆盖 HTTP** | 只有 HTTP/HTTPS host+path 路由;TLS 只能 Terminate | 一个 API 家族覆盖 **HTTP/gRPC/TLS passthrough/TCP/UDP**(§8),还有 mTLS、流量镜像、灰度等一等公民字段 |

Gateway API **不是** Ingress 的 v2 字段升级,而是按"**每类参与者只写自己那层**"重新切分的对象模型。

### 对象模型总览

```
┌───────────────────────── 集群级(基础设施提供方创建) ─────────────────────────┐
│  GatewayClass  controllerName: 实现域名/名字    ← "用哪家实现"                 │
└──────────────────────────────────────────────────────────────────────────────┘
        │ 1:N(spec.gatewayClassName 引用)
┌───────────────────────── 命名空间级(平台/集群操作员创建) ─────────────────────┐
│  Gateway   listeners[]: {port, protocol, hostname, tls, allowedRoutes}      │
│            ← "开哪些门":每个 listener ≈ 数据面上的一个监听端点(LB 端口)        │
│  (ListenerSet: 把多个 Gateway 的 listener 合并到共享数据面,v1.5 GA)          │
└──────────────────────────────────────────────────────────────────────────────┘
        │ 1:N(parentRefs 挂载,可跨命名空间,由 allowedRoutes 控制)
┌───────────────────────── 命名空间级(应用团队创建) ────────────────────────────┐
│  HTTPRoute / GRPCRoute / TLSRoute / TCPRoute / UDPRoute                     │
│            ← "门里的流量往哪走":hostname+path 匹配 + filters + backendRefs   │
│  ReferenceGrant        ← 授权跨命名空间引用(如 route 跨 ns 指 Service)        │
│  BackendTLSPolicy      ← 网关→后端这段的 TLS/mTLS(挂 Service 上)              │
└──────────────────────────────────────────────────────────────────────────────┘
```

一条完整链路的流量顺序(**记牢,排障全靠它**):

```
客户端 → LB/网关地址:port ─(端口+SNI/Host)→ 选定 Listener
        → 挂在该 listener 上、hostnames 与 listener.hostname 相交的 Route 们
        → 按匹配优先级选中恰好一条 rule → filters 加工 → backendRefs 负载均衡
        → Service:port → Pod(端点)
```

- 没有 Route 挂上去时,listener 依然可以 `Accepted=True`——"开了门但没人用"是合法状态;
- 请求匹配不到任何规则 ⇒ 返回 **404**(不是 500;500/503 只发生在"规则命中但后端无效");
- 请求匹配不到任何 listener("Listener Isolation")是 Extended 特性,各实现自行声明。

## 2. 角色分工与权限建议(为什么多团队能用)

| 角色 | 建什么 | 典型 RBAC 边界 | 为什么安全 |
| --- | --- | --- | --- |
| 基础设施提供方 | GatewayClass(集群级) | cluster-admin/实现安装者 | 决定"能用哪种实现" |
| 集群操作员/平台团队 | Gateway(含证书、端口) | 只在 `infra`/`gateways` 命名空间有写权限 | 端口/证书集中治理;应用团队摸不到证书 |
| 应用管理员 | HTTPRoute/GRPCRoute、ReferenceGrant | 本命名空间 | 只能往"放行过的 Gateway"上挂路由 |
| 应用开发者 | Deployment/Service | 本命名空间 workload | 不感知网关 |

应用侧"挂路由"跨命名空间**不需要 ReferenceGrant**(那是有意的设计,见 §9.2 例外),靠
Gateway `listeners[].allowedRoutes.namespaces: Same | All | Selector` 控制放行面:

```yaml
listeners:
- name: https
  protocol: HTTPS
  port: 443
  allowedRoutes:
    namespaces:
      from: Selector                 # Same(默认)| All | Selector
      selector:
        matchLabels:
          gateway-access: enabled    # 只有打了这个标签的命名空间能挂路由上来
    kinds:                           # 可选项;不写则按协议推断(HTTPS→HTTPRoute)
    - kind: HTTPRoute
```

> 设计核心:证书、域名、端口属于"平台能力",路由规则属于"应用表达"——应用想给某个 host 加规则,
> 不需要也**不应该**碰证书。跨团队共享一个 LB,入口数量从"每人一个 LB"降为"每平台一个 Gateway"。

## 3. 版本化模型:两个 Channel + 一个 x 组

### 3.1 Standard vs Experimental

| | Standard channel(生产用它) | Experimental channel(尝鲜) |
| --- | --- | --- |
| 内容 | 全部 GA(v1)资源 | Standard 一切 + alpha 资源 + 未毕业字段 |
| 稳定性承诺 | 有(向后兼容) | **无**(允许破坏性变更、按月度快照演进) |
| 安装 | `standard-install.yaml` | `experimental-install.yaml` |
| 例子 | HTTPRoute 无 `retry/sessionPersistence` 字段 | HTTPRoute 带这些实验字段;另有 `XBackendTrafficPolicy`、`XMesh`、`XBackend` |

- 同一资源在 experimental 安装里可能**同时 serve 多个版本**(如 BackendTLSPolicy 的 v1alpha3 + v1)。
- v1.5+ 的安装包里带 ValidatingAdmissionPolicy `safe-upgrades.gateway.networking.k8s.io`:
  **禁止用实验 CRD 覆盖标准 CRD、禁止降级到 v1.5 之前**,需要时可先删 VAP 再操作。
- 资源 CRD 上有注解 `gateway.networking.k8s.io/channel: standard|experimental` 和
  `gateway.networking.k8s.io/bundle-version`,可自查当前装的是哪套。

### 3.2 发布历史与毕业时间线(v1.0 → v1.6,记住这张表就不会看错旧资料)

| 版本 | 时间 | 关键内容(转正 Standard/GA 为主) |
| --- | --- | --- |
| v1.0.0 | 2023-10 | **首个 GA**:GatewayClass/Gateway/HTTPRoute/ReferenceGrant 到 v1 |
| v1.1.0 | 2024-05 | GRPCRoute 升 v1;GAMMA(路由直挂 Service)GA;HTTPRoute parentRefs.port GA |
| v1.2.0 | 2024-10 | Gateway.infrastructure、HTTPRoute **timeouts**、BackendProtocol 转正;breaking:GRPCRoute/ReferenceGrant v1alpha2 停止服务 |
| v1.3.0 | 2025-04 | **百分比 RequestMirror** 转正;新实验资源一律 **X 前缀 + `gateway.networking.x-k8s.io` 组**(XBackendTrafficPolicy、XListenerSet);HTTPRoute CORS filter 进实验;监听器冲突时建议 421 |
| v1.4.0 | 2025-10 | **BackendTLSPolicy GA**(v1);GatewayClass `status.supportedFeatures`;route rule 命名;ExternalAuth/Default Gateways 进实验 |
| v1.5.0 | 2026-02 | "biggest release":**ListenerSet、TLSRoute、CORS filter、前端 mTLS(frontendValidation)、Gateway→后端客户端证书选择、ReferenceGrant(v1)** 转正 |
| v1.6.0 | 2026-06 | **TCPRoute/UDPRoute GA**(v1),v1alpha2 弃用;新实验资源 XBackend;文档站改版 |
| v1.6.2 | 2026-09 | 当前最新 patch(303/307/308 状态码重定向归为 Extended 等) |

**两个通道版本注意点(反直觉,易错):**

- Standard channel 的资源一律建议写 `gateway.networking.k8s.io/v1`;`v1beta1` 目前只有
  Gateway/GatewayClass/HTTPRoute/ReferenceGrant 还在 serve(v1beta1 的 Go 类型在 v1.5 已删,纯为 CRD 兼容)。
- **beta 版本概念正在被淘汰**:新资源转正直接进 v1,不再走 v1beta1。
- HTTPRoute 有些字段(如 rule 的 `name`)在标准 CRD 已存在但其"唯一性校验"只在实验 CRD——标准里可用但无校验,别依赖。
- 官方承诺支持 Kubernetes 版本:至少最近 5 个 minor(v1.5 博客口径 1.30+;TLSRoute 的 CEL 校验要求 K8s ≥ 1.31)。

## 4. GatewayClass:选实现(集群级,基础设施提供方创建)

功能上≈ IngressClass;`kubectl get gatewayclass`(短名 `gc`)。**多个 GatewayClass 可共存**(如
`internet`/`private`),实现各自的控制器只认自己 `controllerName` 匹配的那一类。

### 4.1 spec 字段

| 字段 | 类型 | 必填 | 默认/约束 | 说明 |
| --- | --- | --- | --- | --- |
| `controllerName` | string | ✓ | **不可变**(CEL `self==oldSelf`);域名前缀路径格式,≤253 | 管理该类 Gateway 的控制器名,建议唯一域名前缀,如 `gateway.envoyproxy.io/gatewayclass-controller`、`gateway.nginx.org/nginx-gateway-controller`。**拼错 = 没控制器认领**,只能重建 |
| `parametersRef` | object | | | 实现自定义的类级参数(自定义 CR 等,可集群级也可命名空间级) |
| `description` | string | | MaxLength=64 | 人类可读描述 |

`parametersRef` 子字段:`group`/`kind`/`name` 必填;`namespace` 只在引用**命名空间级**资源时填写
(集群级资源不能带)。参数无效/找不到 → `Accepted=False, reason=InvalidParameters`。

### 4.2 status

- `conditions[]`:**只有 `Accepted` 一种类型**(早期 v1alpha1 的 `Admitted`、个别旧资料的 `Valid`
  都过时了);新对象默认 `Accepted=Unknown, reason=Pending(message "Waiting for controller")`,
  直到控制器看到它。
- `supportedFeatures[]`(v1.4+):该类实现的特性名列表(字母升序)。

`Accepted` 的 reason:

| status | reason | 含义 |
| --- | --- | --- |
| True | `Accepted` | 控制器接受该类 |
| False | `InvalidParameters` | parametersRef 无效 |
| False | `Unsupported` | 实现只认自己的默认类,不接受自定义 GatewayClass |
| False | `UnsupportedVersion` | CRD 版本不被实现支持 |
| Unknown | `Pending` | 控制器尚未决断(等待中) |

### 4.3 示例

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: internet
spec:
  controllerName: example.net/gateway-controller
  description: Internet-facing gateway class
  parametersRef:
    group: example.net
    kind: Config
    name: internet-gw-config
    namespace: gw-infra
```

## 5. Gateway:开门(命名空间级,平台团队创建)

Gateway 是整族 API 的"触发器"——文档原话:**"A Gateway is 1:1 with the lifecycle of the
configuration of infrastructure"**。创建后,匹配的控制器会:调云 API 建 LB / 拉起软件网关实例 /
向既有 LB 加配置段(实现决定)。短名 `gtw`。

### 5.1 spec 顶层字段

| 字段 | 类型 | 必填 | 默认/约束 | 说明 |
| --- | --- | --- | --- | --- |
| `gatewayClassName` | string | ✓ | | 引用集群级的 GatewayClass(名字即可,无跨 ns 概念) |
| `listeners` | array | ✓ | **1–64 条**,map key = `name` | 每个 ≈ 数据面上一个监听端点 |
| `addresses` | array | | MaxItems=16 | **请求**外侧地址(见 §5.5) |
| `infrastructure` | object | | | labels/annotations/参数,透传给实现创建的资源 |
| `allowedListeners` | object | | 默认 from=None | 哪些 ns 的 ListenerSet 可并入(§5.6) |
| `tls` | object | | | 网关级 TLS:前端客户端证书校验(frontend)+ 上游客户端证书(backend)(§10) |
| `defaultScope` | string | | 实验字段 | "默认网关",让匹配 scope 的 Route 隐式挂载(GEP-3793,实验) |

**注意:spec 里没有副本数/资源配额等字段**——数据面实例怎么部署由实现决定(通常看实现的
GatewayClass 参数或自带资源配置)。

### 5.2 listeners[] 字段(最常用,逐字段)

| 字段 | 类型 | 必填 | 默认/约束 | 说明 |
| --- | --- | --- | --- | --- |
| `name` | string | ✓ | DNS label 格式,≤253,在 Gateway 内唯一 | status.listeners 也用它做 key |
| `port` | int | ✓ | 1–65535 | 直接对应数据面/LB 端口;多 listener 可共用端口(见 distinct 规则) |
| `protocol` | string | ✓ | HTTP/HTTPS/TLS/TCP/UDP(可带域名前缀自定义) | 不支持 → `Accepted=False/UnsupportedProtocol` |
| `hostname` | string | | **不允许 IP**;`*.` 只允许做第一个标签 | 留空 = 匹配所有 hostname;**TCP/UDP 禁止写**(CEL 拒绝) |
| `tls` | object | 条件必填 | HTTPS/TLS 必须;HTTP/TCP/UDP 禁止(CEL) | §5.4 |
| `allowedRoutes` | object | | 默认 `{namespaces: {from: Same}}` | 谁能把什么 Route 挂到这个 listener(§1 已有例) |

**CEL 硬性校验(写错 API Server 直接拒):**

1. protocol ∈ {HTTP, TCP, UDP} 不能带 `tls`;
2. HTTPS + tls → mode 只能空或 `Terminate`;
3. protocol=TLS → 必须有 tls 且 mode 非空;
4. TCP/UDP → 不能有 hostname;
5. listener name 在 Gateway 内唯一;(port, protocol, hostname) 三元组唯一。

**distinct(去重)规则 —— 决定多 listener 何时合法:**

- HTTP/HTTPS/TLS 同协议的多 listener:必须至少在 **(port, hostname)** 上有差异;TCP/UDP:只看 **port**。
- `tls` 配置**不参与** distinct——只差证书的两个 listener 必然冲突(证书靠 SNI 在同一 listener 内区分,或拆不同 hostname)。
- 同端口 HTTP/HTTPS/TLS 与 TCP 混用:实现支持 TCP 时整组不 distinct、一律不接受;实现不支持 TCP 则 TCP listener 不该被接受。
- 冲突结果:冲突的 listener `Conflicted=True`(`HostnameConflict`/`ProtocolConflict`),Gateway
  `Accepted=False, reason=ListenersNotValid`(实现可只接受不含冲突的子集,但至少保留一个 distinct listener)。
- 同端口 hostname 区分时,请求匹配优先级:**精确 hostname > 通配符 > 空 hostname**;多个通配符按更具体(点更多)的优先。

### 5.3 一个端口按域名分证书 + 按域名分流(最常用组合)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: infra
spec:
  gatewayClassName: internet
  listeners:
  - name: https-www            # 同 443 端口两个 listener,靠 hostname 区分
    protocol: HTTPS
    port: 443
    hostname: "www.example.com"
    tls:
      mode: Terminate          # HTTPS 不写默认 Terminate;TLS 协议则必须显式写
      certificateRefs:
      - group: ""              # 空串 = core 组;默认 kind: Secret
        name: www-tls
  - name: https-api
    protocol: HTTPS
    port: 443
    hostname: "api.example.com"
    tls:
      certificateRefs:
      - name: api-tls
    allowedRoutes:
      namespaces:
        from: All              # 让业务团队在各自 ns 挂 api 路由
```

之后在业务命名空间挂 HTTPRoute(跨 ns 挂 Gateway **不需要** ReferenceGrant):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api-route
  namespace: team-a
spec:
  parentRefs:
  - name: shared-gateway       # 省略 namespace = 本 ns;跨 ns 要写全:
    namespace: infra           #   infra/shared-gateway
    sectionName: https-api     # 可选:只挂 https-api 这个 listener
  hostnames:
  - "api.example.com"          # 必须与 listener.hostname 有交集,否则挂不上
  rules:
  - backendRefs:
    - name: team-a-api
      port: 8080
```

### 5.4 listener.tls 字段细节(下行 TLS:客户端 ↔ 网关)

| 字段 | 说明 |
| --- | --- |
| `mode` | `Terminate`(默认)或 `Passthrough`。**Terminate**=网关解 TLS,必须有证书;**Passthrough**=网关不解密、只看 ClientHello 的 SNI,`certificateRefs` 被忽略,只能挂 TLSRoute |
| `certificateRefs[]` | 默认 group=core、kind=Secret;Core 支持 `kubernetes.io/tls` 类型 Secret(键 `tls.crt`/`tls.key`);`namespace` 缺省=Gateway 同 ns;**跨 ns 引用 Secret 必须 ReferenceGrant**(建在 Secret 所在 ns,from 指向 Gateway 的 group/kind/namespace);引用无效 → listener `ResolvedRefs=False, reason=InvalidCertificateRef` 或 `RefNotPermitted` |
| `options` | map(≤16),key 须带域名前缀:实现扩展(如最小 TLS 版本、cipher) |

- Terminate 模式下 `certificateRefs`+`options` 至少有一个非空(CEL),否则直接拒绝。
- 一个 listener 挂**多个证书**属于实现特定行为(Core 只保证单证书),跨实现别依赖。
- 同一个端口要"每个域名各用自己的证书":开多个 hostname 各异的 HTTPS listener(§5.3 例)。
  通配符证书并存时,更具体的 hostname 优先(`foo.example.com` 配专属证书,`*.example.com` 配通配证书)。
- **SNI 两级路由**:① TLS 握手层:SNI 在 listener 间选择(HTTPS 要求 SNI 与 Host 都匹配某 listener;
  SNI/Host 不一致且 Host 能命中别的 listener → 返回 **421 Misdirected Request**,否则 404);
  ② 连接建立后:HTTPRoute 按 hostnames + path 分流。

### 5.5 spec.addresses 与 status.addresses:请求 vs 实际

- `spec.addresses[]` 是对外侧地址的**请求**(`type`: 默认 `IPAddress`,可 `Hostname`/`NamedAddress`/实现自定义;`value` 可空=请求自动分配)。Extended 特性。
- **`status.addresses[]` 由控制器回填**已绑定地址(云 LB 的 IP/域名)——排查看它,别只看 spec。
- 指定地址不可用 → `Programmed=False`(`AddressNotUsable`/`AddressNotAssigned`);类型不支持 → `Accepted=False/UnsupportedAddress`。

### 5.6 附加能力

- `spec.infrastructure.labels/annotations`(≤8/16 个):透传给实现创建的资源(如
  `linkerd.io/inject: enabled`、`istio-injection: enabled` 做 sidecar 注入;v1.2+ Standard)。
- `parametersRef`(Gateway 级,只能引用本 ns 资源):本 Gateway 的实现参数(通常 GatewayClass 给默认、Gateway 覆盖)。
- **ListenerSet**(v1.5 GA):把多个 Gateway 的 listener 合并到**同一套数据面**,解决"每个 Gateway
  一个独立 LB 实例"的资源放大问题;Route 的 parentRefs 也可直接指向 ListenerSet。

### 5.7 Gateway status 速查

**Gateway 级条件**:

| 条件类型 | True 的 reason | False 的常见 reason | 语义 |
| --- | --- | --- | --- |
| `Accepted` | `Accepted`/`ListenersNotValid` | `Invalid`/`InvalidParameters`/`UnsupportedAddress`/`ListenersNotValid` | spec 有效到足以产生数据面配置(≠ 已下发) |
| `Programmed` | `Programmed` | `Invalid`/`Pending`/`NoResources`/`AddressNotAssigned`/`AddressNotUsable` | 配置已生成,数据面将很快就绪 |
| `ResolvedRefs` | `ResolvedRefs` | `RefNotPermitted`/`InvalidClientCertificateRef`/`ListenersNotResolved` | 顶层引用有效(实验条件) |
| `Ready` | — | — | **保留给未来**,实现不得使用;别等它判断可用性! |
| `Scheduled` | — | — | 已弃用(用 Accepted) |

**每个 listener 的条件**(status.listeners[],含 `attachedRoutes` = 成功挂载的 Route 数,
`supportedKinds[]` = 实际支持的 Route 类型):

| 条件类型 | True 的 reason | False 的常见 reason | 备注 |
| --- | --- | --- | --- |
| `Accepted` | `Accepted` | `PortUnavailable`/`UnsupportedProtocol`/`UnsupportedValue`/`NoValidCACertificate` | 无 Route 也可 True |
| `Conflicted` | `NoConflicts` | `HostnameConflict`/`ProtocolConflict` | False 时不设置即视为无冲突 |
| `ResolvedRefs` | `ResolvedRefs` | `InvalidCertificateRef`/`InvalidRouteKinds`/`RefNotPermitted`/`InvalidCACertificateRef`/`InvalidCACertificateKind` | Secret/引用解析 |
| `Programmed` | `Programmed` | `Invalid`/`Pending` | |
| `Detached` | — | — | **已弃用**,按 Accepted 理解(旧资料里的 `Resynced` 条件从未存在过,忽略) |

判断口诀:**Gateway 看 Accepted+Programmed,Listener 看 listeners[].conditions,挂载量看 attachedRoutes。**

## 6. HTTPRoute:流量规则(全族最常用,字段最全)

`apiVersion: gateway.networking.k8s.io/v1`。约束上限:rules ≤16、每条 rule 的 matches ≤64、
全路由 matches 总数 ≤128、hostnames ≤16、filters ≤16、backendRefs ≤16。

### 6.1 spec 结构

```
spec:
  parentRefs[]     ← 挂到谁(哪个 Gateway / 哪个 listener / Service(mesh 模式))
  hostnames[]      ← 只处理这些域名(可空 = 任意 hostname)
  rules[]          ← 路由规则(最多 16;每个请求恰好命中一条)
    name?          ← v1.4 起 Standard CRD 已带(唯一性校验在实验通道)
    matches[]      ← 匹配条件(条间 OR、条内 AND)
    filters[]      ← 命中后对请求/响应做的加工(重定向/改写头/镜像等)
    backendRefs[]  ← 转发目标(可多个,按 weight 分流)
    timeouts       ← request / backendRequest(Standard 自 v1.2,Extended)
    retry?         ← 实验字段(experimental-install 才有)
    sessionPersistence? ← 实验字段(experimental-install 才有)
status:
  parents[]: 按 parentRef 分别上报 Accepted/ResolvedRefs/PartiallyInvalid
```

### 6.2 parentRefs[](CommonRouteSpec,所有 Route 共用)

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `group` | `gateway.networking.k8s.io` | 想指 core 组资源(如 Service)必须显式 `group: ""` |
| `kind` | `Gateway` | Core 支持的 parent 只有两种:**Gateway**(网关)/ **Service**(mesh profile,仅 ClusterIP Service) |
| `name` | —(**必填**) | |
| `namespace` | Route 自身 ns | 跨 ns 挂 Gateway 由 Gateway 的 allowedRoutes 决定,不走 ReferenceGrant |
| `sectionName` | 无 | 对 Gateway = **listener 的 name**;不写 = 附着整个 Gateway 上所有兼容 listener;写了但没这个 listener → 该 parentRef 被忽略(`NoMatchingParent`) |
| `port` | 无 | 目标 = 该端口上所有兼容 listener(Extended);与 sectionName 同给时需同时匹配。不建议依赖(改端口要跟着改 route) |

- 判定:**至少一个 parent/listener 接受 ⇒ Route Accepted=True**;全拒 ⇒ `Accepted=False`(reason
  见 §14.3)。没有可挂的 parent 时,实现**可能完全不写状态**(out of scope),"无状态"本身就是诊断线索。
- CEL:同一 parent 重复引用必须一致地都带/都不带 sectionName,且 sectionName 唯一。

### 6.3 hostnames[](可省略,≤16)

- 匹配请求的 Host 头(忽略端口);**禁止 IP**;允许首 label 单通配符 `*.`(纯后缀匹配:
  `*.example.com` 匹配 `a.example.com` 和 `a.b.example.com`,**不匹配裸 `example.com`**)。
- 与 listener.hostname 的**交集**关系决定能否附着:
  - listener=`test.example.com` ⇐ 可挂:hostnames 为空,或含 `test.example.com`/`*.example.com` 的 route;
  - listener=`*.example.com` ⇐ 可挂:hostnames 为空,或含 `*.example.com`/`test.example.com`/`foo.test.example.com`;
    `example.com`(裸)、`test.example.net` 不行;
  - listener hostname 留空 = 与一切 route 相交(也意味着可能"接盘"意外流量)。
- route 里与 listener 不相交的 hostname 条目被忽略;全部不相交 ⇒ 不附着(`NoMatchingListenerHostname`)。
- **rules 作用于整条 route 的所有 hostnames**(和 Ingress 每 host 一套规则不同)——多 host 各要不同
  规则就拆成多条 HTTPRoute。

### 6.4 matches[]:条间 OR,条内 AND

```yaml
matches:                                # (A且B) 或 C
- path: {type: PathPrefix, value: /v1}  # A
  method: GET                           # B
  headers: [{name: env, value: prod}]
- path: {type: Exact, value: /v2/foo}   # C
```

| 匹配维度 | 类型 | 默认 | 支持级别与要点 |
| --- | --- | --- | --- |
| `path.type` | `Exact` / `PathPrefix` / `RegularExpression` | `PathPrefix` | **Exact**:大小写敏感全等(`/abc` ≠ `/abc/`);**PathPrefix**:按 `/` 分隔的路径元素前缀匹配(`/abc` 命中 `/abc/def`,`/abcd` 不命中);**RegularExpression**:**Implementation-specific**——只保证"按正则、大小写敏感",方言(POSIX/PCRE/RE2)由实现定,查实现文档 |
| `path.value` | string | `/` | Exact/PathPrefix 必须以 `/` 开头、≤1024、禁 `//`/`/./`/`/../`/`%2f`/`#` 等 |
| `headers[]` | `Exact`(默认)/`RegularExpression` | — | ≤16,条内 AND;name 不区分大小写(HTTP/2 pseudo-header 不行);**值默认区分大小写**(无 ignoreCase 字段);一个 rule 内同名 header 只取第一条 |
| `queryParams[]` | `Exact`(默认)/`RegularExpression` | — | ≤16,条内 AND;Extended;重复 query 参数语义未定义,别依赖 |
| `method` | enum(大写) | 无=不限制 | `GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH`;Extended |

单条 match 里省略字段 = 该维度不限制;整个 `matches` 省略 ⇒ 默认一条
`{path: {type: PathPrefix, value: "/"}}`(匹配一切)。

### 6.5 filters[]:命中后加工

通用规则:

- ≤16;**同类型 filter 一条 rule 内只能出现一次**(RequestMirror、ExtensionRef 例外,允许多个);
- **RequestRedirect 与 URLRewrite 互斥**(同 rule 内 CEL 拒绝);RequestRedirect 与 backendRefs 不能同 rule,URLRewrite 可以和 backendRefs 共存(改写后转发);
- 执行顺序:规范只要求"尽可能按书写顺序",**没有绝对契约**,生产按常见习惯编排并看实现文档;
- 不支持的 filter type ⇒ 整条 route `Accepted=False/UnsupportedValue`;ExtensionRef 引用解析失败时**禁止跳过**,命中请求必须收到 HTTP 错误。

| filter 类型 | 子字段 | 要点 |
| --- | --- | --- |
| `RequestHeaderModifier`(Core)/`ResponseHeaderModifier`(Extended) | `set[]`/`add[]`(name,value)、`remove[]` | 同一 header 只能选一种动作(set/add/remove 互斥);add 追加在已有值后 |
| `RequestRedirect`(Core) | `scheme`(http/https)、`hostname`、`path`、`port`、`statusCode` | statusCode 默认 **302**(301/302/303/307/308);scheme/port 缺省时用请求 scheme/listener 端口(80/443 通常不写进 Location) |
| `URLRewrite`(Extended) | `hostname`、`path` | path 改写:type `ReplaceFullPath`(整路径换)或 `ReplacePrefixMatch`(**只允许与恰好一个 PathPrefix match 同 rule**);替换按完整路径元素:`match /foo` + `replacePrefixMatch /xyz` 时 `/foo/bar` → `/xyz/bar`;空串=去掉前缀 |
| `RequestMirror`(Extended) | `backendRef`(必填)、`percent`(0-100)或 `fraction{numerator,denominator}` | 副本发往该后端一个端点,响应被忽略;**percent/fraction 二选一,不给=100%**(v1.3 起 Standard);跨 ns 后端需 ReferenceGrant |
| `ExtensionRef` | `group`/`kind`/`name` | 仅同 ns 对象;Implementation-specific 扩展点 |
| `CORS`(v1.5 起 Standard) | `allowOrigins[]`/`allowCredentials`/`allowMethods[]`/`allowHeaders[]`/`exposeHeaders[]`/`maxAge` | CORS 结构化表达 |
| `ExternalAuth`(实验,v1.4+) | protocol HTTP/GRPC、backendRef 等 | 外部认证;失败默认 fail-closed |

> 注:`set` 的 value 想表达"多值"用逗号串(RFC 7230),不是重复 `set`。

### 6.6 backendRefs[]:转发目标与流量拆分

```yaml
backendRefs:
- name: store-v1        # group 默认 ""(core),kind 默认 Service
  port: 8080            # Service 时必须填(service port,不是 targetPort)
  weight: 90
- name: store-v2
  namespace: store-v2ns # 跨 ns 必须显式写,且要 ReferenceGrant(§9)
  port: 8080
  weight: 10            # 单后端且 >0 ⇒ 100% 转发;weight: 0 = 关闭该后端(灰度)
```

- **weight 语义**:`weight / 本列表权重和`,和不要求 =100。
- filters 也可以写在单个 backendRef 上(`HTTPBackendRef.filters`):仅当请求转发到该后端时执行(Implementation-specific)。
- 失效行为(**没有"自动 fallback"这个概念,别指望**):
  - 全部 backendRefs 无效且无会产生响应的 filter ⇒ 命中请求 **500**;
  - 部分无效:本应发给无效后端的**那部分按权重吃 500**(如两个等权后端一个无效 ⇒ 约 50% 流量 500);
  - 后端 Service 无 ready 端点 ⇒ **503**(同样按权重分摊);
  - 无效定义:kind 不支持(`InvalidKind`)、对象不存在(`BackendNotFound`)、跨 ns 无 RG(`RefNotPermitted`)、
    appProtocol 不兼容/BackendTLSPolicy 无法满足(`UnsupportedProtocol`)——均须 `ResolvedRefs=False`;
  - 空 backendRefs + 空 filter ⇒ 500;空 backendRefs + 有 RequestRedirect 等响应型 filter ⇒ 合法(响应由 filter 产生)。

### 6.7 timeouts / retry / session persistence(运维三件套)

```yaml
rules:
- timeouts:                    # Standard 自 v1.2(Extended 支持)
    request: 30s               # 客户端整个事务超时
    backendRequest: 10s        # 网关→单个后端单次请求超时;不得大于 request(CEL)
  retry:                       # ★实验字段,需 experimental-install
    attempts: 3                # 最大重试次数(v1.6 起强制 ≥1)
    codes: [502, 503, 504]     # 500-599 整数;元素唯一;500/502/503/504 必须支持
    backoff: 500ms             # 最小等待(实现可用指数退避+jitter,但不得早于它重试)
  sessionPersistence:          # ★实验字段
    type: Cookie               # Cookie(Core)/ Header(Extended);默认 Cookie
    sessionName: my-cookie     # ≤128
    absoluteTimeout: 1h        # 会话绝对过期
    cookieConfig:
      lifetimeType: Permanent  # Session(默认,会话 cookie)/ Permanent(必须配 absoluteTimeout)
```

细节:

- Duration 格式:GEP-2257 严格子集,单位只有 `h/m/s/ms`(最多 4 段,如 `1h30m`);`0s`=禁用;非零 ≥1ms。
- retry 配置了之后,实现 SHOULD 对连接类错误(断开/重置/超时/TCP 失败)重试;**所有重试总时长不得突破 `request` 超时**。
- v1.3 起官方把"面向后端的重试预算/会话保持"实验重心移到 XBackendTrafficPolicy(v1.6 又加了 XBackend),
  HTTPRoute 上的 retry/sessionPersistence 仍在但演进方向是后者——新项目尝鲜建议先看实现文档怎么推。
- v1.6 起实验版 sessionPersistence 删掉了 `idleTimeout` 字段(历史遗留)。

### 6.8 规则优先级与多 Route 合并(v1.6 模型,与 Ingress 完全不同的确定性)

规范模型是 **"每个请求恰好命中一条 rule + 全确定性优先级"**,不是"多条规则同时生效再拼装":

1. 候选:请求先锁定 **listener**(端口+SNI/Host),再收集挂在该 listener 上、hostnames 相交的 Routes;
   **"本 listener 没匹配上"不会落到别的 listener**,直接 404。
2. 逐条 rule 按 match 优先级裁决(同一 rule 内平局看书写顺序),**优先级从高到低**:

   `Exact path` → 字符数最多的 `PathPrefix` → 有 method 匹配 → header 匹配数最多 → queryParam 匹配数最多
   (`RegularExpression` path 的优先级由实现自定)

3. 跨 Route 平局:**creationTimestamp 最老** 的 Route 赢 → 再平局按 `namespace/name` 字母序;
   同一 Route 内平局 → 列表序第一条胜出。
4. 任何已附着规则都没命中 ⇒ **404**。

**与 HTTPRoute 规则相关的坑:**

- HTTPRoute 与 GRPCRoute 在同一 listener 上 hostnames 交集非空 ⇒ 实现必须只接受其一(MUST),
  按"最老→字母序"裁决,且二者规则**不得合并**。
- 部分 rule 无效时置 `PartiallyInvalid=True`(不会整体 Accepted=False),实现可丢弃无效规则
  (消息带 `Dropped Rule...`)或整体回退(`Fall Back...`)。
- 早期资料里"Gateway API 会把同一 listener 上多条路由的规则合并求值"的说法在 v1.x 早已被
  上面的"单规则+优先级"模型取代,按本节为准。

## 7. 各 Route 的最小可用 YAML(照抄可跑)

### 7.1 HTTPRoute + 灰度

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: app-gateway
  namespace: default
spec:
  gatewayClassName: example-class      # 换成你装的实现的 GatewayClass 名
  listeners:
  - name: http
    protocol: HTTP
    port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store-route
spec:
  parentRefs:
  - name: app-gateway
    sectionName: http
  hostnames:
  - "store.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1
      method: GET
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        set:
        - name: x-env
          value: prod
    backendRefs:
    - name: store-v1
      port: 8080
      weight: 90
    - name: store-v2
      port: 8080
      weight: 10
  - matches:
    - path:
        type: Exact
        value: /healthz
    backendRefs:
    - name: store-v1
      port: 8080
```

### 7.2 HTTPS 终结 + HTTP→HTTPS 跳转

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: https-gateway
  namespace: default
spec:
  gatewayClassName: example-class
  listeners:
  - name: http
    protocol: HTTP
    port: 80
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: example-tls         # kubernetes.io/tls 类型 Secret,与本 Gateway 同 ns
---
# 80 端口只干一件事:跳到 https(挂在 http listener 上,hostnames 任意)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: redirect-to-https
  namespace: default
spec:
  parentRefs:
  - name: https-gateway
    sectionName: http
  hostnames:
  - "www.example.com"
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        port: 443
        statusCode: 301
---
# 443 上的真实路由
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: www-route
  namespace: default
spec:
  parentRefs:
  - name: https-gateway
    sectionName: https
  hostnames:
  - "www.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web
      port: 8080
```

## 8. 其余 Route 类型

### 8.1 GRPCRoute(Standard 自 v1.1)

- 与 HTTPRoute 同族:parentRefs + hostnames + rules(matches/filters/backendRefs/sessionPersistence),≤16 rules。
- **差异**(全是减法):没有 path、没有 queryParams、没有 HTTP method、**没有 timeouts/retry**;
  filters 只有 RequestHeaderModifier(Core)/ResponseHeaderModifier/RequestMirror/ExtensionRef。
- matches 结构:

```yaml
rules:
- matches:                       # 条间 OR,条内 AND
  - method:
      type: Exact                # Exact(默认)/ RegularExpression(Implementation-specific)
      service: com.example.User  # gRPC 服务名;与 method 至少一个非空;省略一侧 = 任意
      method: Login              # gRPC 方法名
    headers:                     # 与 HTTPHeaderMatch 同构
    - name: version
      value: "2"
  backendRefs:
  - name: user-svc
    port: 50051
```

- 协议前提:挂 HTTPS listener 需支持 ALPN h2(不是 HTTP/1.1 upgrade);挂 HTTP listener 需支持
  h2c prior-knowledge;不满足 ⇒ listener 对该 GRPCRoute `Accepted=False/UnsupportedProtocol`。
- 失败语义:全部后端无效且无响应型 filter ⇒ RPC 收到 **UNAVAILABLE**;backendRefs 为空且无响应型 filter ⇒ **UNIMPLEMENTED**。
- gRPC status 级重试建议留给策略类 API,别塞在 rule 里。
- HTTP+gRPC 混跑同一域名建议用 HTTPRoute 以 `/pkg.Svc/Method` path 统一处理;纯 gRPC 用 GRPCRoute。

### 8.2 TLSRoute(Standard 自 v1.5):SNI 分发非 HTTP TLS 流量

- 模型:`spec.hostnames`(**必填**,1–1024,SNI 匹配,禁 IP,通配规则同 HTTPRoute)+ `rules`
  (**恰好 1 条**:backendRefs 1–16,可带 name/weight)。没有 path/header 等过滤。
- 只能挂 `protocol: TLS` 的 listener:
  - `tls.mode: Passthrough` = **Core**:网关只按 SNI 选后端,整条加密流透传(SNI 在 ClientHello 明文);
  - `tls.mode: Terminate` = Extended(特性 `TLSRouteModeTermination`):网关终结 TLS 后以明文 TCP 转发,可配 BackendTLSPolicy 与后端重加密。
- 后端无效/无端点 ⇒ **按权重拒绝连接**。
- 典型:Kafka/Postgres/WebRTC/mTLS 直连等非 HTTP TLS 协议按 SNI 分流。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: tls-gw
spec:
  gatewayClassName: example-class
  listeners:
  - name: tls
    protocol: TLS
    port: 443
    tls:
      mode: Passthrough
---
apiVersion: gateway.networking.k8s.io/v1
kind: TLSRoute
metadata:
  name: kafka-route
spec:
  parentRefs:
  - name: tls-gw
    sectionName: tls
  hostnames:
  - "kafka.example.com"
  rules:
  - backendRefs:
    - name: kafka-svc
      port: 9092
```

### 8.3 TCPRoute / UDPRoute(Standard 自 v1.6):纯 L4

- 模型:没有 hostnames、没有 matches——**listener 端口就是全部匹配依据**;rules 恰好 1 条(backendRefs + weight)。
- 后端 Service 支持:**TCP = Core;UDP = Extended**(注意差异)。无效/无端点:TCP 按权重**拒绝连接**,UDP 按权重**丢包**。
- 典型:数据库/Redis/DNS/VoIP/游戏等非 HTTP 协议的 L4 转发(共享端口、灰度)。

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: tcp-gw
spec:
  gatewayClassName: example-class
  listeners:
  - name: mysql
    protocol: TCP
    port: 3306
---
apiVersion: gateway.networking.k8s.io/v1
kind: TCPRoute
metadata:
  name: mysql-route
spec:
  parentRefs:
  - name: tcp-gw
    sectionName: mysql
  rules:
  - backendRefs:
    - name: mysql-svc
      port: 3306
```

### 8.4 实验资源(X 前缀,X 组)

| 资源 | 组/版本 | 干什么 | 状态 |
| --- | --- | --- | --- |
| `XBackendTrafficPolicy` | `gateway.networking.x-k8s.io/v1alpha1` | 后端流量策略:重试预算(retry budget,超预算重试必须 503)、会话保持 | Experimental(v1.3+) |
| `XMesh` | 同上 | mesh 级全局配置 | Experimental(v1.4+) |
| `XBackend` | 同上 | 通用 backend 装饰器:首批支持 ExternalHostname 目的地(访问外部云 API 等 egress 场景) | Experimental(v1.6 新增) |

## 9. ReferenceGrant:跨命名空间引用的"介绍信"

### 9.1 是什么

Route 可以引用**别的命名空间**的 Service,Gateway 可以引用别的命名空间的 Secret——但没有授权,
这类跨 ns 引用一律无效(防 confused-deputy 类漏洞,CVE-2021-25740 的教训)。授权方式:在
**被引用对象所在命名空间**建 ReferenceGrant。默认 `apiVersion: gateway.networking.k8s.io/v1`
(v1beta1 仍兼容;v1 与 v1beta1 同时被 serve,推荐写 v1)。

### 9.2 哪些引用需要 / 不需要它

需要(跨命名空间时):

- 所有 xRoute 的 `backendRefs` → 别的 ns 的 Service/后端;
- Gateway listener 的 `certificateRefs`/CA 引用 → 别的 ns 的 Secret/ConfigMap;
- 其它跨 ns 对象引用(extensionRef 等)。

**例外(不需要):**

- **Route → Gateway 的跨 ns 挂载**:不走 ReferenceGrant,由 Gateway 的
  `allowedRoutes.namespaces`(Same/All/Selector)管——这是最常被搞错的点;
- 同命名空间引用。

### 9.3 字段与示例

| 字段 | 语义 |
| --- | --- |
| `spec.from[]` | 发起引用的来源:`group`+`kind`+`namespace` **三个都必填**;**故意没有 name**(能写某 ns 某类资源的人总能改名绕过,名字没意义);不支持 selector |
| `spec.to[]` | 可被引用的目标:`group`+`kind`,name **可选**(省略=该 kind 任意名);**没有 namespace**——RG 所在 ns 就是目标 ns |

```yaml
# ns=team-b 的 HTTPRoute 想转发到 ns=platform 的 Service
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: allow-team-b-to-platform
  namespace: platform          # ★必须建在被引用资源(Service)所在的命名空间
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: team-b          # 只放行 team-b 的 HTTPRoute
  to:
  - group: ""
    kind: Service              # 可加 name: xxx 收紧到指定 Service
```

同时,跨 ns 的 backendRefs 里**必须显式写 `namespace:`**(不写默认本 ns,照样找不到)。

常见错误:① RG 建到了 route 的 ns 而不是目标资源的 ns;② `from`/`to` 的 group 写错(HTTPRoute 的
group 是 `gateway.networking.k8s.io`,Service 的 group 是空 `""`);③ 忘记跨 ns Secret 也要 RG;
④ 期望它管 Route→Gateway 挂载(不需要)。

## 10. TLS 全链路图:三张"证书桌"要分清

Gateway API 把 TLS 拆成**互相独立的三段**,配置位置各不同:

```
①下行(客户端→网关)         ②上行的证书校验(网关→后端)     ③上行的客户端身份(网关→后端)
   加密 + 服务器证书          校验后端证书链(SAN/SNI)         网关出示自己的客户端证书(mTLS)
   ─────────────────        ───────────────────────        ─────────────────────────────
   listener.tls:            BackendTLSPolicy(挂 Service)   Gateway.spec.tls.backend.
   mode/certificateRefs                                     clientCertificateRef(v1.5)
```

| 段 | 配置位置 | 支持级别 |
| --- | --- | --- |
| ① 客户端→网关(服务器证书、Terminate) | Gateway `listeners[].tls` | Core |
| ①' 透传(不终结,SNI 分流) | `protocol: TLS` + `tls.mode: Passthrough` | Core(配 TLSRoute) |
| ①'' 客户端证书校验(前端 mTLS) | Gateway `spec.tls.frontend`(default + perPort[]):`caCertificateRefs`(ConfigMap 的 `ca.crt` 键)+ `mode: AllowValidOnly`(默认)/`AllowInsecureFallback` | Standard 自 v1.5(Extended 支持);放 Gateway 级而不是 listener 级,防 HTTP/2 连接聚合绕过校验;用 InsecureFallback 会置 `InsecureFrontendValidationMode=True` 条件 |
| ② 后端证书校验 | **BackendTLSPolicy** 挂 Service(§11) | Standard 自 v1.4 |
| ③ 网关作为 TLS 客户端出示证书 | Gateway `spec.tls.backend.clientCertificateRef`(core 组 `kubernetes.io/tls` Secret;跨 ns 需 ReferenceGrant) | Standard 自 v1.5 |

**关键点:HTTPRoute 上没有任何 TLS 字段**——证书由平台在 Gateway 管,应用挂路由时不配证书;
HTTPRoute 默认以明文 HTTP 转发到后端,想加密到后端就上 BackendTLSPolicy。

## 11. 策略附件(Policy Attachment)与 BackendTLSPolicy

### 11.1 模型

"给某个对象附加设置"用**元资源(policy)**表达,不用注解(Gateway API 明确**不推荐**在自身资源上
用注解做扩展;扩展点只有三个:extensionRef/自定义后端、实现自己的 CRD、Policy 附件):

- **Direct Policy Attachment**:只影响被指向的那一个对象(如 BackendTLSPolicy 挂 Service,
  "所有指向该 Service 的 Route 都应遵守");
- **Inherited(继承)**:挂到祖先,影响整棵对象树(实验概念,GEP-713,整体仍标 Experimental);
- **Defaults/Overrides** 机制仍在设计中——**当前已落地的官方策略都没有 defaults/overrides**,
  别指望"父策略强制覆盖子配置",策略尽量挂到最贴近目标的资源上;
- 同一目标多个策略:实现裁决只让一个生效,其余置 `Accepted=False, reason=Conflicted`;优先级规则
  由 GEP-713 与实现定义,跨实现不可移植。

官方标准策略目前就一个:**BackendTLSPolicy**(实验的 BackendTrafficPolicy 见 §8.4)。
各实现自带的同名扩展(如 Envoy Gateway 的 SecurityPolicy/RateLimitFilter)不是标准 API,用法查实现文档。

### 11.2 BackendTLSPolicy 字段(v1,Standard 自 v1.4)

用途:**网关→后端这段启用 TLS/mTLS**("backend TLS termination"),和客户端方向的 listener TLS 无关。

| 字段 | 说明 |
| --- | --- |
| `spec.targetRefs[]` | 只能指**同命名空间**的 Service;1 个以上 |
| `spec.validation.hostname` | 网关连后端用的 **SNI**,必须与后端证书匹配;禁 IP、禁通配符 |
| `spec.validation.caCertificateRefs[]` | PEM CA,**≤8 个、禁止跨 ns**;Core 支持 = 单个 ConfigMap,证书必须放在 key `ca.crt` |
| `spec.validation.wellKnownCACertificates` | 当前枚举值 `System`(用系统信任库,开发环境);与 caCertificateRefs **二选一** |
| `spec.validation.subjectAltNames[]` | ≤5;校验后端证书 SAN(支持 SPIFFE URI SAN);Extended 特性 `BackendTLSPolicySANValidation` |
| `spec.validation.options` | map:实现特定 TLS 选项 |
| `status.ancestors[]` | 每个控制器一组 conditions(`Accepted`/`ResolvedRefs`,reason 如 `InvalidCACertificateRef`/`InvalidKind`/`NoValidCACertificate`/`Conflicted`) |

解析失败 ⇒ 相关连接必须让客户端收到 HTTP 5xx。

```yaml
# 后端 Pod 里跑着 TLS(证书由你的 CA 签发,含 SAN),下面是"网关→它"的 mTLS 配置
apiVersion: v1
kind: ConfigMap                  # CA 证书放这里(与后端同 ns)
metadata:
  name: backend-ca
  namespace: app
data:
  ca.crt: |
    -----BEGIN CERTIFICATE-----
    ...
---
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: secure-backend
  namespace: app                # 必须与目标 Service 同 ns
spec:
  targetRefs:
  - group: ""
    kind: Service
    name: my-backend
  validation:
    hostname: my-backend.app.svc.cluster.local   # 作 SNI,须与后端证书匹配
    caCertificateRefs:
    - group: ""
      kind: ConfigMap
      name: backend-ca          # key 必须是 ca.crt
    # 开发环境也可二选一:
    # wellKnownCACertificates: System
```

## 12. 服务网格(GAMMA):路由直挂 Service

- 从 v1.1 起,"Service Mesh"方向(社区叫 GAMMA)已 Standard:HTTPRoute 的 `parentRefs` 可以直接
  **指向 Service**(mesh 数据面拦请求,按 route 决策)。
- mesh 模式**通常不用 Gateway/GatewayClass**:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: smiley-route
  namespace: faces
spec:
  parentRefs:
  - name: smiley
    group: ""          # core 组
    kind: Service
    port: 80
  rules:
  - backendRefs:
    - name: smiley-v2
      port: 80
```

- **producer route**(route 与 Service 同 ns):影响所有调用方;跨 ns = **consumer route**:只影响
  route 所在 ns 的出站调用(如只给某调用方 100ms 超时)。同一 ns 无法给多个调用方分别定义 consumer route。
- 请求不匹配任何已挂接 route 时被拒;无 route 挂接时按 mesh 默认行为转发。
- mesh 方向的实现(如 Istio、Cilium)对 consumer route / 单 Service 多 route 的完成度不一,用前查实现文档(网格版 HTTPRoute 目前只覆盖 HTTPRoute)。

## 13. 安装一个能跑的实验环境(kind)

> 版本(2026-09-05 核对):kind v0.33、Envoy Gateway v1.9.1、NGINX Gateway Fabric v2.7.0、Istio 1.31。
> 与 TLS 系列一样建议用 kind;本仓库 `kubernetes/gVisor/` 有 kind 集群排障笔记可参考。

```bash
brew install kind
kind create cluster --name=gw-test
# kind 没有 LoadBalancer 实现 → Gateway 的 .status.addresses 为空。
# 方案 A(推荐):cloud-provider-kind → https://github.com/kubernetes-sigs/cloud-provider-kind
# 方案 B:MetalLB(Envoy Gateway quickstart 用的方案)
# 都不装也行:用下文 port-forward / NodePort 分支访问
```

### 13.1 Envoy Gateway(conformance 最高,官方支持 kind,推荐主线)

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.1 \
  -n envoy-gateway-system --create-namespace
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

# 官方 quickstart(内含 GatewayClass eg + Gateway + HTTPRoute + echo 后端,整包一个文件)
kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/v1.9.1/quickstart.yaml -n default

# 无 LB 时端口转发访问(把 8888 映射到网关 Service 的 80)
export ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system \
  --selector=gateway.envoyproxy.io/owning-gateway-namespace=default,gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward service/$ENVOY_SERVICE 8888:80 &
curl -v -H "Host: www.example.com" http://localhost:8888/get

# 有 LB(MetalLB / cloud-provider-kind)时:
GATEWAY_HOST=$(kubectl get gateway/eg -o jsonpath='{.status.addresses[0].value}')
curl -v -H "Host: www.example.com" http://$GATEWAY_HOST/get
```

### 13.2 NGINX Gateway Fabric(想玩 TCP/UDP/TLS 全协议就选它)

```bash
# 先装 standard CRD(实现 pin 好版本)
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.7.0" | kubectl apply -f -
helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --create-namespace -n nginx-gateway \
  --set nginx.service.type=NodePort          # kind 无 LB 时的官方参数
kubectl wait --timeout=5m -n nginx-gateway deployment/ngf-nginx-gateway-fabric --for=condition=Available
kubectl get gatewayclass nginx               # 安装后自动建好,ACCEPTED=True

kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.7.0/examples/cafe-example/cafe.yaml
kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.7.0/examples/cafe-example/gateway.yaml
kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.7.0/examples/cafe-example/cafe-routes.yaml
# NodePort 访问(端口以你环境为准;官网 kind 教程是 31437):
curl --resolve cafe.example.com:31437:127.0.0.1 http://cafe.example.com:31437/coffee
```

### 13.3 Istio(想顺带玩服务网格就用它)

```bash
curl -L https://istio.io/downloadIstio | sh - && cd istio-1.31.0 && export PATH=$PWD/bin:$PATH
istioctl install -f samples/bookinfo/demo-profile-no-gateways.yaml -y   # 入口交给 Gateway API
kubectl label namespace default istio-injection=enabled
kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null || \
  kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.6.0" | kubectl apply -f -
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml
kubectl apply -f samples/bookinfo/gateway-api/bookinfo-gateway.yaml

kubectl annotate gateway bookinfo-gateway networking.istio.io/service-type=ClusterIP   # kind 无 LB
kubectl port-forward svc/bookinfo-gateway-istio 8080:80
curl http://localhost:8080/productpage
```

> 注意点:网关 Service 在 kind 上必须走 NodePort / port-forward / LB 组件三者之一;
> Gateway `Programmed=True` 不代表有外部地址——**看 `.status.addresses` 是否被填充**。

## 14. Ingress → Gateway API 迁移

官方指南:`/guides/getting-started/migrating-from-ingress/`(另有一份 Ingress-NGINX 专项
`migrating-from-ingress-nginx/`),自动转换工具见 **ingress2gateway** 项目(结果必须人工验证)。

### 14.1 概念对应表

| Ingress | Gateway API | 备注 |
| --- | --- | --- |
| `spec.ingressClassName`/IngressClass | `spec.gatewayClassName`/GatewayClass + HTTPRoute.parentRefs | **不是字段替换**:入口资源(端口/证书)归集群操作员所有,要先建好 Gateway |
| `spec.rules[].host` | HTTPRoute `hostnames[]` | 语义差:HTTPRoute 的 rules 对全部 hostnames 生效,同 host 同规则才合并成一条 |
| `paths[].path` + `pathType` | `matches[].path`(`PathPrefix`≈Prefix/`Exact`≈Exact) | Prefix 语义更精确(按路径元素) |
| `backend.service.name/port` | `backendRefs[](name/port/weight)` | 支持多后端加权、跨 ns(+ReferenceGrant) |
| `spec.tls[].hosts/.secretName` | listener `tls.mode: Terminate` + `certificateRefs` | Secret 同 ns 可复用;跨 ns 要 ReferenceGrant |
| 默认后端(default backend) | **没有直接等价**;显式建一条 `PathPrefix: /` 规则指向默认后端 | |
| 注解:重定向/改写/header 路由/流量切分等 | HTTPRoute 的结构化 filters/字段(§6.5/§6.6) | 官方向导说这些"现在已是 API 一部分" |
| 注解:限流/WAF/认证/健康检查等 | 实现扩展(extensionRef / 实现自带策略),**无标准等价物** | |
| host 匹配与证书由 controller 决定 | listener.allowedRoutes 显式控制谁可挂载 | 安全模型 |

### 14.2 手动迁移三步法(官方模式,可照抄)

1. **建 Gateway**:一个 Gateway 对应原 Ingress 的隐式入口——HTTP:80 与 HTTPS:443(Terminate,
   复用同一 Secret)两个 listener,可用 `hostname: "*.example.com"`、allowedRoutes 收紧范围;
2. **拆 HTTPRoute**:按 hostname 拆——同一域名多条 path 规则并入一条 HTTPRoute 的多个 rules;
   不同域名各自一条 HTTPRoute;`parentRefs` 指向 Gateway(可 `sectionName: https`);
3. **TLS 跳转**:挂到 http listener 的一条 HTTPRoute,`RequestRedirect{scheme: https, port: 443}`,
   取代 `ssl-redirect` 类注解。

注意点:同一域名内 rewrite 范围不同(path 级)就拆成多条 rule/route,可读可测;注解翻成 filters
翻不动的(限流等)在目标实现里找扩展重配;Secret/Service 同 ns 全可复用;Gateway API 可与 Ingress
**并存灰度**(先小流量验证再切 DNS);default backend、TLS redirect 等行为每个实现有差异,做一轮对照回归。

### 14.3 常见 Ingress-NGINX 注解映射

| Ingress-NGINX 注解 | Gateway API |
| --- | --- |
| `nginx.ingress.kubernetes.io/rewrite-target` | filter `URLRewrite`(type: ReplacePrefixMatch,配 PathPrefix 匹配) |
| `nginx.ingress.kubernetes.io/ssl-redirect: "true"` | filter `RequestRedirect`(scheme: https) |
| `nginx.ingress.kubernetes.io/canary-*` / 权重 | backendRefs + `weight` |
| `nginx.ingress.kubernetes.io/enable-cors` / `cors-*` | HTTPRoute **CORS filter**(v1.5 起 Standard,注意实现支持) |
| `nginx.ingress.kubernetes.io/backend-protocol: HTTPS` | **BackendTLSPolicy**(同类能力的新标准表达) |
| `limit-rps`/`proxy-connect-timeout`/`configuration-snippet` | 无标准等价物 → 实现扩展(EG 的 RateLimitFilter/BackendTrafficPolicy、NGF 的 Policy 等) |

## 15. 排障手册

### 15.1 铁律与命令序列

1. **永远先看 `status.conditions`**,且先核对 `observedGeneration == metadata.generation`
   (不等 = 控制器没跟上,状态过期);
2. **"没有状态"本身是线索**:parentRef 无效 / 对象不在该实现的管辖 scope 内时,实现不写状态;
3. 跨 ns 问题先查 ReferenceGrant;证书问题先看 Secret 的 key 名(`tls.crt`/`tls.key`)与类型。

```bash
kubectl get gatewayclass,gateway,httproute -A        # 一眼看全
kubectl get gateway -A -o wide                       # PROGRAMMED? ADDRESS?
kubectl describe gateway <name> -n <ns>              # 逐 listener 看条件
kubectl describe httproute <name> -n <ns>            # 每个 parentRef 的 Accepted/ResolvedRefs
kubectl get httproute <name> -n <ns> -o yaml         # status.parents[].conditions 原文
kubectl get events -A --field-selector involvedObject.kind=HTTPRoute
kubectl get referencegrant -A                        # 跨 ns 引用问题先查它
kubectl get secret <tls-secret> -n <ns> -o yaml      # data 里有没有 tls.crt/tls.key
gwctl describe gateway <name> -n <ns>                # 官方 CLI,渲染更友好(§16)
```

### 15.2 症状 → 原因 → 动作

| 症状 | 常见原因 | 动作 |
| --- | --- | --- |
| Gateway 一直 `Accepted=False/Pending` | GatewayClass 不存在/`gatewayClassName` 拼错/controllerName 与实现不符 | `kubectl get gatewayclass -o yaml` 对 controllerName;describe 看 message |
| GatewayClass 没被接受 | controllerName 不是该实现的 | 对照实现文档里的 controllerName 常量 |
| `Programmed=False` 且无地址 | kind 等环境没有 LB | 装 MetalLB/cloud-provider-kind,或 port-forward/NodePort(§13) |
| Listener `Conflicted: HostnameConflict` | 同端口 hostname 重叠(含精确 vs 通配) | 检查同端口 listener 的 hostname 唯一性 |
| Listener `ResolvedRefs=False RefNotPermitted` | 证书 Secret 跨 ns 没 ReferenceGrant | 在 Secret ns 建 RG(from=Gateway 的 group/kind/ns) |
| Listener `ResolvedRefs=False InvalidCertificateRef` | Secret 缺 `tls.crt`/`tls.key`/非 PEM | `kubectl get secret -o yaml` 核对 |
| HTTPRoute `Accepted=False NoMatchingListenerHostname` | route hostnames 与 listener.hostname 无交集 | 对齐两者(§6.3 交集规则) |
| HTTPRoute `Accepted=False NoMatchingParent` | parentRef 的 name/ns 写错、sectionName 无对应 listener | 核对 Gateway 名与 listener name |
| HTTPRoute `ResolvedRefs=False RefNotPermitted` | backendRefs 跨 ns 无 RG / 忘了写 namespace | 在 Service ns 建 RG |
| HTTPRoute 完全没 status | parentRef 无效 / out of scope | 查 parent 是否存在、实现是否认这个 GatewayClass |
| 命中规则却 500/503 | 后端无效/无 ready 端点(无 fallback 语义) | 看 ResolvedRefs 的 reason,修后端 |
| 行为与文档不符 | 实现 conformance 差异(extended/实验/注解扩展) | 查官方 conformance 表 + 实现文档,回归测试 |

## 16. 工具与验证

| 工具 | 干什么 | 备注 |
| --- | --- | --- |
| **gwctl**(`github.com/kubernetes-sigs/gwctl`) | 官方 CLI:`gwctl get gateways -A`、`gwctl describe gateway/httproute`、`gwctl explain gatewayclass` | **没有**官方 "kubectl gateway" 插件,官方推荐 gwctl + kubectl describe |
| conformance 套件 | 随 gateway-api 仓库发布,`go test ./conformance/...` | 用户侧价值:官方版本表当"实现能力对照表" |
| curl | HTTP/SNI 验证:`curl -sk --resolve www.example.com:443:<IP> https://www.example.com/` | `-H "Host: ..."` 测虚拟主机 |
| openssl s_client | 看 SNI/TLS 握手与证书链 | `openssl s_client -connect <IP>:443 -servername www.example.com` |
| grpcurl | gRPC 验证 | `grpcurl -insecure -authority grpc.example.com <IP>:443 pkg.Svc/Method` |
| ingress2gateway | Ingress → Gateway 自动转换 | 结果必须人工验证 |

官方实现能力对照表(会随版本变动,查最新):`gateway-api.sigs.k8s.io/docs/implementations/versions/v1.6/`。
截至 2026-09-05 的概貌:Envoy Gateway v1.9(36/38,缺 TLS/TCP/UDP xRoute)、NGINX Gateway Fabric
v2.7(30/38,xRoute 覆盖最全 + BackendTLSPolicy + ListenerSet)、Cilium v1.20(29/38)、Istio(网关+网格双
conformant,但 L4 xRoute 需 alpha 开关)、GKE(12/40)、AWS LB Controller(partial)。Contour 已退出官方名单。
**本地入门:Envoy Gateway 最稳;想全协议就 NGINX Gateway Fabric。**

## 17. 学习路线与参考

- 官方文档站(2025-2026 改版后的新路径,旧 /api-types/xxx 多已 404):
  - API 类型字段:`https://gateway-api.sigs.k8s.io/reference/api-types/httproute/`(同目录 gateway/grpcroute/tlsroute/referencegrant/...)
  - 完整字段规范:`https://gateway-api.sigs.k8s.io/reference/api-spec/1.6/spec/`
  - 版本化/发布节奏:`/concepts/versioning/`;流量匹配优先级:`/concepts/traffic-matching/`
  - 排障:`/concepts/troubleshooting/`;策略附件:`/reference/policy-attachment/`;GEP 列表:`/geps/`
  - 用户向导:`/guides/user-guides/`(traffic-splitting、tls、grpc-routing、http-redirect-rewrite、http-timeouts、multiple-ns、infrastructure…)
  - mesh:`/docs/mesh/`
- 发布说明博客:kubernetes.io/blog 搜 "gateway-api"(v1.3–v1.6 各有一篇,含 zh-cn)
- 源码与 CRD 权威:`github.com/kubernetes-sigs/gateway-api`,`config/crd/{standard,experimental}/`
- 本仓库相关笔记:TLS 系列(证书/SNI/mTLS 概念,网关 TLS 字段背后正是这些)、gVisor(kind 集群实验)

**版本自检口诀**:先 `kubectl get crd gateways.gateway.networking.k8s.io -o yaml | grep bundle-version`
看装的是哪版;Standard 只认 v1 写法;实验功能只存在于 experimental-install 的 CRD 里
(没有字段 = 大概率装的是 standard 包,先别怀疑实现有 bug)。
