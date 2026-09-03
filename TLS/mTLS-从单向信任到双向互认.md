# mTLS 深潜:从"单向信任"到"双向互认"

> 单向 TLS 解决"服务器是不是真的",mTLS 追问的是"敲门的人是不是自己人"。这篇从信任模型讲到握手差异,再到 nginx 双向认证从零跑通——看完你就能自己搭一套服务间认证。

## 01 单向信任:浏览器时代的设计

### 为什么平时"只有服务器出示证书"

你天天访问 HTTPS 网站,都是服务器出示证书、浏览器验证——为什么客户端不用证明自己?

因为浏览器时代的设计假设是:

1. **服务器是稀缺的、固定的**:全世界就一个 example.com,它必须证明"我是 example.com"
2. **客户端是海量的、匿名的**:任何浏览器用户都允许访问公开网页,不需要(也不应该)暴露身份
3. **信任锚是系统预置的**:浏览器内置几百个受信根 CA,验证服务器的链

这套设计服务于"任何人访问公开网站",非常成功——但它默认了一个前提:**服务器需要被验证,客户端不需要**。

### 这个模型在服务间对话时失灵

当对话双方变成"服务 A ↔ 服务 B",单向信任的漏洞立刻显现:

- 攻击者攻破内网一台机器,可以**伪装成任何服务**(它只需要骗过"客户端",而客户端根本不验证对方——不,单向 TLS 客户端是验证服务器的……准确地说:服务 A 作为客户端访问服务 B 时,它验证了 B 的证书——但 B 无法验证调用它的是不是真的 A)
- 更致命的反向场景:**谁都能调用你的内部 API**——只要证书合法(或走了内网),服务 B 无法区分"真 A"和"伪装成 A 的攻击者"
- 审计需求:出了事故,你无法证明"哪个服务在什么时间调用了什么"

> 关键认知:单向 TLS 验证的是"连接的另一端有合法证书",而**任何一端都能拿到一张合法证书**——它证明不了"调用者是谁"。mTLS 补上的正是这一环:让连接的两端互相证明身份。

## 02 mTLS 握手:多了哪两步

### 握手差异对比

对比单向 TLS 1.2 握手,mTLS 只是多了两个环节——但方向完全反转:

- STEP 01:客户端发 ClientHello(与单向一致,带 SNI、密套列表)
- STEP 02:服务器发 ServerHello + 证书链,**额外发一个 CertificateRequest**("请你也出示证书")
- STEP 03:客户端验证服务器证书;**客户端出示自己的证书链**(Certificate 消息)
- STEP 04:**客户端用私钥对握手摘要签名**(CertificateVerify 消息),证明"我确实持有这张证书对应的私钥"
- STEP 05:双方完成密钥交换,开始加密通信

> 绿色提示:第 04 步是 mTLS 的灵魂——Certificate 本身可以伪造(证书是公开的),但**CertificateVerify 必须用私钥签名**,服务器验证签名后,才能确定"持证人在场"。这是"证明我是我"的密码学落地。

### 验证路径:从单向到双向

```
单向 TLS:  客户端 ——验证--> 服务器证书 ——链到--> 客户端信任的根 CA
mTLS:      客户端 ——验证--> 服务器证书 ——链到--> 客户端信任的根 CA
           服务器 ——验证--> 客户端证书 ——链到--> 服务器信任的根 CA
```

注意一个细节:**双方可以信任不同的 CA**。你的内部服务信任公司内部 CA 签发的客户端证书,同时仍然信任公共 CA 签发的服务器证书——两端各有各的信任锚。

## 03 为什么服务间需要 mTLS

### 三个真实场景

1. **B2B/内部 API**:支付网关、用户中心这类敏感服务,只接受持有合法客户端证书的调用方——比 API Key 更安全(私钥不随代码走,无法被日志泄露)
2. **微服务集群**:服务间调用频繁,用户名密码/Token 的接入审计成本高——证书即身份
3. **物联网/设备认证**:设备出厂预置证书,平台用 mTLS 区分"这台设备"和"仿冒设备"

### mTLS 与 API Key 的对比

| 维度 | API Key | mTLS |
| --- | --- | --- |
| 泄露风险 | 明文头,日志/截图/前端都可能泄露 | 私钥不出设备 |
| 冒充难度 | 偷到 Key 即可冒充 | 需要私钥 |
| 传输保护 | 依赖 TLS 保护头 | 自带加密通道 |
| 轮换成本 | 改配置 | 换证书(可短生命周期) |
| 审计 | 无标准 | 证书 CN/SAN 可审计 |

> 一句话亮点:API Key 是"进门报口令",mTLS 是"进门刷身份证还按指纹"——口令能抄,指纹不能。

## 04 动手:nginx 双向认证从零跑通

这一节完整搭一套:内部 CA → 服务端证书 → 客户端证书 → nginx 开启双向校验 → curl 验证"不带证书被拒、带证书放行"。

### 第一步:创建内部 CA

```bash
# 1. 生成 CA 私钥
openssl genrsa -out ca.key 2048

# 2. 自签 CA 根证书(有效期 10 年,CN 写"Internal Root CA")
openssl req -x509 -new -key ca.key -days 3650 \
  -subj "/CN=Internal Root CA" -out ca.crt
```

### 第二步:签发服务端证书(带 SAN)

```bash
# 1. 服务端密钥对 + CSR
openssl genrsa -out server.key 2048
openssl req -new -key server.key \
  -subj "/CN=example.com" -out server.csr

# 2. CA 签名,必须带 SAN(现代客户端只看 SAN)
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -days 365 -out server.crt \
  -extfile <(echo "subjectAltName=DNS:example.com,DNS:localhost,IP:127.0.0.1")
```

### 第三步:签发客户端证书

```bash
# 客户端身份就写在 CN 里——证书即身份
openssl genrsa -out client.key 2048
openssl req -new -key client.key \
  -subj "/CN=client-01/OU=payment-service" -out client.csr

openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -days 365 -out client.crt
```

### 第四步:nginx 开启双向认证

```nginx
server {
    listen       8443 ssl;
    server_name  example.com;

    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;

    # ===== mTLS 核心:客户端证书校验 =====
    ssl_client_certificate /etc/nginx/certs/ca.crt;   # 信任的 CA(我们的内部 CA)
    ssl_verify_client      on;                         # 强制校验:拿不出证书直接拒
    ssl_verify_depth       2;                          # 允许的证书链深度

    location / {
        # 把客户端身份透传给后端应用
        proxy_set_header X-Client-CN   $ssl_client_s_dn;
        proxy_set_header X-Client-Verify $ssl_client_verify;
        proxy_pass http://127.0.0.1:8080;
    }
}
```

### 第五步:验证双向认证生效

```bash
# 1. 不带客户端证书 → 握手被拒(400 或握手失败)
curl -k https://127.0.0.1:8443/
# HTTP/2 400 ... client certificate required  ← 服务器说:请出示证件

# 2. 带客户端证书 → 放行
curl -k --cert client.crt --key client.key https://127.0.0.1:8443/
# 200 OK

# 3. 带一张"别人 CA 签的"证书 → 还是被拒(信任链断裂)
curl -k --cert other-ca.crt --key other.key https://127.0.0.1:8443/
# 400 ... failed to verify client certificate
```

> 踩坑提示:nginx 校验的是**证书链是否可追溯到 ssl_client_certificate 里的 CA**,不是"证书有没有过期"那么简单——签发客户端证书的 CA 必须与服务器配置的 CA 一致,否则必然 400。

### 服务器如何知道"谁在敲门"

nginx 暴露了三个变量,后端应用靠它们做授权:

```bash
$ssl_client_verify   # SUCCESS / FAILED / NONE
$ssl_client_s_dn     # 客户端证书 Subject,如 /CN=client-01/OU=payment-service
$ssl_client_i_dn     # 签发该证书的 CA
```

后端拿到 `X-Client-CN`,按 CN 前缀做授权(如 `payment-service` 才能调支付接口)——**这就是"证书即身份"的应用层落地**。

## 05 内部 PKI:为 mTLS 造一个信任锚

### 信任锚的设计

mTLS 的强度不取决于 TLS 本身,而取决于**你信任的 CA 有多可靠**:

```
根 CA(离线保管,几乎不签叶子)
 └── 中间 CA A(服务器证书签发)
 └── 中间 CA B(客户端证书签发)   ← 按用途拆分,吊销/轮换互不影响
```

拆分的理由:

1. **隔离风险**:一个中间 CA 私钥泄露,只吊销它的证书,根 CA 不用动
2. **职责分离**:签发服务器证书的流程和签发客户端证书的流程可以走不同的审批
3. **短期证书成为可能**:中间 CA 可以只签 24h/7d 的证书——证书越短,吊销需求越小,轮换自动化越简单

### 证书轮换的哲学:mTLS 场景下"短命证书"是解药

单向 TLS 的证书可以一年一换,因为吊销体系(CRL/OCSP)能兜底。但 mTLS 的客户端证书有个现实困境:**被吊销的客户端证书,直到 CRL 更新前都还能用**(吊销滞后)。于是行业共识变成:

> 与其设计完美的吊销,不如让证书短命——24 小时一签,泄露了也只用防一天。这就是 SPIFFE 体系把证书有效期压到小时级的原因。

## 06 架构实践:网格、网关与零信任

### 微服务网格:Sidecar 之间的 mTLS

Istio 这类服务网格把 mTLS 变成默认项:

```
[Pod A: Sidecar] ——— mTLS ———> [Pod B: Sidecar]
     |                               |
   服务 A                           服务 B
```

- 每个 Pod 的 Sidecar 持有短期证书(SPIFFE 体系签发),服务代码**完全无感知**
- 默认 STRICT 模式:集群内流量全部强制 mTLS,明文流量直接拒绝
- 意义:**横向移动被阻断**——攻破 Pod A,想访问 Pod B 的服务,必须过 B 的 Sidecar 这关,而 A 的证书只授权给 A 的身份

### API 网关与 B2B:对外 mTLS

网关对外可以同时开两种模式:

- **面向浏览器**:普通 TLS(客户端匿名)
- **面向合作方/内部系统**:mTLS(按证书 CN 区分合作方,自动路由到对应的限流与账单策略)

nginx 用 `ssl_verify_client optional` 实现"同端口双模式":

```nginx
ssl_verify_client optional;   # 有证书就校验,没有也放行到应用层判断
```

应用层再按 `$ssl_client_verify` 分流:SUCCESS → 走 B2B 逻辑;NONE → 走公开逻辑。

### 零信任里的位置

零信任的核心假设是"内网不等于可信"。mTLS 是零信任的**传输层基石**:每次调用都要证明身份,不因为"我们在同一个内网"就放行。但记住:mTLS 只解决"谁在调用",**调用权限(能不能调这个接口)要由应用层或授权策略(SPIFFE 联邦、RBAC)继续管**。

## 07 运维与坑

> 每个坑配**真实复现**(现象/排查/修复/验证四步),输出来自 `TLS/labs` 实验环境(8443 为 `ssl_verify_client on` 的 mTLS 前端,证书由自带 lab CA 签发)。命令在 `TLS/labs/` 下执行;若本机配了 HTTP 代理,curl 需加 `--noproxy '*'`。一键复现:`bash start.sh` + 对应场景脚本。

### 坑一:证书轮换断了线上

客户端证书到期后,所有调用方一起 401/400——**mTLS 的证书轮换必须两端协调**:先给所有调用方发新证书并灰度切换,再等旧证书自然过期,不能一刀切。

**现象**:一台消费方的客户端证书 2024-09-01 就过期了,它还在照常调用,服务端直接拒绝:

```bash
$ openssl x509 -in certs/out/client-expired.crt -noout -subject -dates
subject=CN=client-expired, OU=payment-service
notBefore=Jan  1 00:00:00 2024 GMT
notAfter=Sep  1 00:00:00 2024 GMT          ← 过期一年了

$ curl -k --cert certs/out/client-expired.crt --key certs/out/client-expired.key \
       -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/
400                                       ← 服务器说:证件无效

# nginx 访问日志,一眼看出 verify=FAILED(还带了原因):
# "GET / HTTP/1.1" 400 ssl_verify=FAILED:certificate has expired cn="CN=client-expired"
```

**排查**:先分清是"证书问题"还是"没带证书"——两个都试:

```bash
$ curl -k -o /dev/null -w 'no-cert: http_code=%{http_code}\n' https://127.0.0.1:8443/
no-cert: http_code=400                    # 没带证书也是 400,但日志里 verify=NONE

$ openssl x509 -in certs/out/client-expired.crt -noout -enddate
notAfter=Sep  1 00:00:00 2024 GMT          # 关键区分:FAILED + 过期原因 → 证书有效性问题
```

**修复**:根因是签发时有效期太长又没人盯到期。正确姿势:**短命证书(如 90 天)+ 到期前自动续签**,客户端先灰度换新、等旧的自然过期再统一切:

```bash
# 给这台消费方先发新证书,灰度切过去(服务端无需动作,信任的是 CA 不是某张证书)
$ curl -k --cert client-new.crt --key client-new.key https://127.0.0.1:8443/
```

**验证**:换上有交期的证书立即可用,服务端视角 SUCCESS:

```bash
$ curl -k --cert certs/out/client-alice.crt --key certs/out/client-alice.key https://127.0.0.1:8443/
backend: ... client_cn=[OU=payment-service,CN=client-01] client_verify=[SUCCESS]
```

> 复现脚本:`bash scenarios/07-1-client-cert-expired.sh`。要点:一刀切 = 全线 400;轮换要两端协调。

### 坑二:忘记 SAN

服务端证书没有 SAN,现代客户端直接拒绝——生成 CSR 时的 `-extfile` 那行不能省。

**现象**:8443 的服务器证书换成只有 CN(www.example.com)、没有 SAN 的那张,本机 curl(CN 兼容)照样通——**以为没事,其实严格模式的调用方(Go/Java 默认)已经全拒了**:

```bash
$ curl --cert certs/out/client-alice.crt --key certs/out/client-alice.key \
       -k --resolve www.example.com:8443:127.0.0.1 https://www.example.com:8443/
backend: ... client_cn=[OU=payment-service,CN=client-01] client_verify=[SUCCESS]
# ↑ CLI 工具全绿;Chrome/强校验库直接拒 → 证书"能用"是假象
```

**排查**:看扩展区有没有 SAN(空 = 没有):

```bash
$ openssl x509 -in certs/out/server-nosan.crt -noout -ext subjectAltName
No extensions in certificate                                    ← 问题证书

$ openssl x509 -in certs/out/server-www.crt -noout -ext subjectAltName
X509v3 Subject Alternative Name:
    DNS:www.example.com, DNS:example.com, DNS:localhost, IP Address:127.0.0.1
```

**修复**:回到 04 章的同款签发姿势——CA 签名时 SAN 行不能省(详见②篇 09 坑二的完整前后对比):

```bash
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -days 365 -out server.crt \
  -extfile <(echo "subjectAltName=DNS:www.example.com,DNS:localhost,IP:127.0.0.1")
```

**验证**:换回带 SAN 的证书后服务恢复,`client_verify=[SUCCESS]`。

> 复现脚本:`bash scenarios/07-2-server-no-san.sh`。要点:SAN 不是可选项;自签流程里把 SAN 写进签发命令,和 CSR 一样是默认动作。

### 坑三:吊销滞后

CRL 更新周期内,被盗客户端证书依然有效。缓解:短生命周期证书 + 及时上报 + CRL/OCSP 尽量高频更新。

**现象**:这张客户端证书在 CA 侧已被吊销(index.txt 标了 R),但校验方**不主动查 CRL 就照样 OK**——吊销形同虚设:

```bash
$ grep -E "^R" certs/out/ca/index.txt
R  ...  1002  unknown  /CN=client-revoked      ← CA 侧确实吊销了

$ openssl verify -CAfile certs/out/ca/lab-ca.crt certs/out/client-revoked.crt
certs/out/client-revoked.crt: OK              ← 不查 CRL:照样通过!
```

**排查**:带上 CA 发布的 CRL 再验,立刻现形:

```bash
$ openssl verify -CAfile certs/out/ca/lab-ca.crt \
       -CRLfile certs/out/ca/lab-ca.crl -crl_check certs/out/client-revoked.crt
error 23 at 0 depth lookup: certificate revoked
```

滞后窗口就写在 CRL 里(一天一更,窗口期内被盗证书"一直有效"):

```bash
$ openssl crl -in certs/out/ca/lab-ca.crl -noout -lastupdate -nextupdate
lastUpdate=Sep  3 ... 2026 GMT
nextUpdate=Sep  3 ... 2027 GMT                ← 下次更新前,校验方都查不到这次吊销
```

**修复**:nginx 的 `ssl_client_certificate` 本身**不查 CRL/OCSP**,缓解靠三条:① 客户端证书短命+自动重签(吊销窗口自然收敛)② 有条件上 OCSP/服务端自行校验 ③ 泄露即上报,吊销动作要快(lab 里的真实吊销过程:签发→revoke→gencrl→`-crl_check` 立刻报 revoked)。

**验证**:把 `-crl_check` 加进巡检——好证书 OK,被吊销的证书报错:

```bash
$ openssl verify -CAfile ... -CRLfile ... -crl_check certs/out/client-alice.crt
certs/out/client-alice.crt: OK
# (client-revoked 在同一命令下:error 23 certificate revoked)
```

> 复现脚本:`bash scenarios/07-3-revocation-lag.sh`。要点:吊销是被动的"后悔药",滞后窗口客观存在;短命证书+自动化才是主动解药。

### 坑四:把客户端私钥塞进代码仓库

客户端证书是"身份凭证",私钥泄露等于身份泄露——私钥必须走密钥管理(KMS/HSM)或加密存储,绝不能进 git、不能进镜像层、不能进日志。

**现象**:事故仓库里躺着客户端私钥,全仓扫描一搜一个准:

```bash
$ grep -rl "BEGIN.*PRIVATE KEY" out/_git-leak-demo
out/_git-leak-demo/payment-service/keys/payment-service.pem     ← 私钥在仓库里
```

**排查**:三条检出命令——全仓扫描 / git 内容检索 / git 历史:

```bash
$ grep -rn "BEGIN.*PRIVATE KEY" out/_git-leak-demo --include="*.pem"
.../payment-service.pem:1:-----BEGIN PRIVATE KEY-----

$ git log --all --oneline --name-only | grep -B1 "payment-service.pem"
payment-service/keys/payment-service.pem    ← 历史里进过仓库(commit 之后仍可检出)
```

**修复**:第一步**立刻停用并重签发**(泄露过的私钥=作废,别指望收回);第二步移除并加 .gitignore——但注意,这只解决未来:

```bash
$ rm keys/payment-service.pem && echo "keys/*.pem" >> .gitignore
$ git add -A && git commit -qm "chore: remove leaked key, ignore key files"
```

**验证**:工作区干净了,但历史**没抹等于没删**——`git log -S` 还能捞回完整私钥:

```bash
$ grep -rn "BEGIN.*PRIVATE KEY" . && echo "(全仓无密钥内容)"
(全仓无密钥内容)                          # 工作区:干净

$ git log --all -p -S 'BEGIN PRIVATE KEY' --oneline | head -6
0f16ece chore: remove leaked key, ignore key files
diff --git a/payment-service/keys/payment-service.pem ...
index 571c984..0000000
--- a/payment-service/keys/payment-service.pem
+++ /dev/null                              # 历史:删除提交里躺着完整私钥!
```

第三步必须用专用工具重写历史:`git filter-repo --path keys/payment-service.pem --invert-paths`(或 BFG),然后全员轮换密钥、清 reflog、收编钩子防再犯。

> 复现脚本:`bash scenarios/07-4-key-in-git.sh`(构造迷你事故仓库→检出→移除→证明历史残留)。要点:进过 git 的私钥一律当泄露处理。

### 坑五:双向验证开了,后端没接身份

nginx 校验了证书,但后端不读 `$ssl_client_s_dn` 做授权——那 mTLS 就只是个"昂贵的连接加密"。**身份要一直传到应用层才有意义**。

**现象**:谁持有效证书都能进——nginx 只校验"证书有效",不过问"你是谁":

```bash
# client-01(被授权的调用方):
$ curl -k --cert certs/out/client-alice.crt --key certs/out/client-alice.key https://127.0.0.1:8443/
backend: ... client_cn=[OU=payment-service,CN=client-01] client_verify=[SUCCESS]

# client-02(别的服务,本不该访问支付服务):照样 200
$ curl -k --cert certs/out/client-bob.crt --key certs/out/client-bob.key \
       -w 'http_code=%{http_code}\n' https://127.0.0.1:8443/
backend: ... client_cn=[OU=payment-service,CN=client-02] client_verify=[SUCCESS]
http_code=200
```

**排查**:看后端有没有消费 nginx 透传的身份头,还是收到就当没看见:

```bash
$ grep -n "X-Client" nginx/nginx.conf.gen
64:            proxy_set_header X-Client-CN     $ssl_client_s_dn;    ← 透传了吗?
# 应用里是否校验 X-Client-CN / 做鉴权?                              ← 消费了吗?
# 上面两个请求回显里 client_verify 都是 SUCCESS,后端却一视同仁——问题不在 TLS,在授权层
```

**修复**:用证书身份做白名单——nginx 层先拦一道(map 只放行 CN=client-01;注意 openssl 3 的 DN 是 `OU=...,CN=...` 顺序,用"CN 结尾"匹配):

```nginx
map $ssl_client_s_dn $authz {
    default 0;
    "~CN=client-01$" 1;              # 只放行 client-01
}
server {
    ...
    if ($authz = 0) { return 403; }  # 身份不在白名单 → 拒
}
```

**验证**:client-01 放行(200),client-02 被拦(403):

```bash
$ curl -k --cert certs/out/client-alice.crt --key certs/out/client-alice.key -w 'http_code=%{http_code}\n' https://127.0.0.1:8443/
backend: ... client_verify=[SUCCESS]
http_code=200

$ curl -k --cert certs/out/client-bob.crt --key certs/out/client-bob.key -w 'http_code=%{http_code}\n' https://127.0.0.1:8443/
<html><head><title>403 Forbidden</title></head>...
```

> 复现脚本:`bash scenarios/07-5-verify-not-consumed.sh`。要点:`verify_client` 只回答"证书有效吗";授权(谁可以进来)必须由应用/网关消费证书身份。

### 坑六:测试环境也用"真 CA"

测试证书应由测试用的独立 CA 签发,和生产的 CA 严格分开——防止测试证书在生产被意外信任。

**现象**:测试环境 nginx 的 `ssl_client_certificate` 直接抄了生产配置,信任的是**生产 CA bundle**:

```nginx
# 测试环境 nginx(错误示范:抄生产)
server {
    listen 8443 ssl;
    ssl_client_certificate /etc/pki/prod/ca-bundle.pem;  # ← 生产 CA!
    ssl_verify_client on;
}
```

危害:测试环境签的"测试证书",因为测试机信任生产 CA,**在生产网络里也能通过校验**——边界从此模糊;测试私钥一旦泄露,等于拿到半张生产门禁卡。

**排查**:审计命令,把所有环境配置里的信任 CA 全捞出来:

```bash
$ grep -rn "ssl_client_certificate\|ssl_trusted_certificate" <各环境配置目录>
.../test-nginx-prod-ca.conf:4:    ssl_client_certificate /etc/pki/prod/ca-bundle.pem;  # ← 命中!
```

**修复**:环境隔离三件套——① 每套环境一个独立 CA(测试用自己的 lab CA,生产独立根)② 证书与配置按环境参数化,CA 路径不许写死 ③ 测试信任根绝不能出现在生产的 truststore / `ssl_client_certificate` 里:

```nginx
# 正确示范:独立测试 CA
server {
    listen 8443 ssl;
    ssl_client_certificate /etc/nginx/certs/ca/lab-ca.crt;   # 测试 CA
    ssl_verify_client on;
}
```

**验证**:复检配置,只剩测试 CA 引用、再无 prod 字样(本仓库全部 lab 证书由 lab CA 签发,与生产 PKI 两套信任互不相通):

```bash
$ grep -rn "ssl_client_certificate\|prod" <配置目录>
.../test-nginx-test-ca.conf:4:    ssl_client_certificate /etc/nginx/certs/ca/lab-ca.crt;
```

> 复现脚本:`bash scenarios/07-6-test-uses-prod-ca.sh`。要点:信任是传染的——测试环境接生产 CA 的那一刻,隔离就没了。

> 绿色提示:排查 mTLS 问题三板斧——`curl -vk` 看握手失败在哪一步、`openssl verify -CAfile ca.crt client.crt` 验证证书链、nginx 日志里看 `$ssl_client_verify` 是 SUCCESS 还是 FAILED(1.30+ 还会带上原因,如 `FAILED:certificate has expired`)。

## 08 与身份体系的配合

### mTLS ≠ 用户身份

mTLS 证明的是"**这台设备/这个服务**持有一张由可信 CA 签发的证书",不等于"**这个人类用户**是谁"。Web 场景里用户身份仍靠 OIDC/SSO,设备身份才靠 mTLS——两者是叠加关系,不是替代关系。

### SPIFFE:服务身份的事实标准

SPIFFE(发音 spiffy)定义了服务身份的标准格式:

```
spiffe://trust-domain/ns/namespace/sa/service-account
        └─信任域     └──────── 路径 = 身份声明 ────────┘
```

X.509-SVID 是它的证书载体——证书里的 SAN 直接编码 SPIFFE ID。Istio、Consul、SPIFFE 生态都遵循它。设计启示:**证书的 CN/SAN 不只是名字,是机器可读的身份声明**,值得认真设计你的命名规范。

## 写在最后

mTLS 的完整故事是一条线:

**单向 TLS 验证"服务器是真的"→ 服务间场景需要"调用者是真的"→ 握手多出两步(CertificateRequest + CertificateVerify)→ 证书变成身份凭证 → 身份凭证需要自己的 PKI → PKI 需要短命证书与自动化 → 网格把这一切变成默认。**

记住三个判断句:**mTLS 解决"谁在敲门",不解决"能敲哪扇门"**;客户端私钥=身份本身,泄露等同沦陷;证书越短命,mTLS 越好运维。

---

📚 本系列共四篇,建议按①→④顺序阅读;系列总览见 [TLS 学习笔记](README.md):

- **① [正向代理与反向代理详解](正向代理与反向代理详解.md)** —— 代理流向基础:谁站在客户端身边,谁站在服务器面前
- **② [代理×TLS 深潜:终结、透传与桥接](代理×TLS-终结透传与桥接.md)** —— termination / passthrough / bridging,从握手到抓包
- **③ [mTLS:从单向信任到双向互认](mTLS-从单向信任到双向互认.md)** —— 服务间认证,证书即身份
- **④ [证书的那些事:从 CSR 到过期](证书的那些事-从CSR到过期.md)** —— PKI 体系、签发流程与生命周期运维

> 我是 {{作者名}},{{一句话简介}}。如果你觉得今天这篇有收获,欢迎**点赞、在看、转发**三连,我们下篇见。
