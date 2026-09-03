# 证书的那些事:从 CSR 到过期

> 前两篇反复提到证书,这一篇把它彻底拆开:一张证书里到底有什么?它怎么被签出来?为什么浏览器相信它?它怎么过期、怎么吊销、怎么自动化?——读完你能独立管理一套证书体系。

## 01 一张证书里有什么

### 用 openssl 拆开看看

证书不是"文件",是一段 ASN.1 编码的结构化数据。用 openssl 把它翻译成人话:

```bash
openssl x509 -in server.crt -text -noout
```

输出里的核心字段(按重要性排):

1. **Subject(主体)**:这是"谁的证书",如 `CN=example.com`
2. **SAN(主题备用名)**:**证书绑定的域名/IP 列表**——现代客户端校验的是这里,不是 CN。`DNS:example.com, DNS:*.example.com, IP:127.0.0.1`
3. **Issuer(签发者)**:谁签的这张证书,如 `CN=R10, O=Let's Encrypt`
4. **有效期**:`Not Before` / `Not After`——过期瞬间失效
5. **公钥**:证书的核心载荷(如 RSA-2048 或 EC P-256),配合私钥使用
6. **签名算法与签名**:CA 用它的私钥对以上内容签名——**签名让内容不可篡改**
7. **扩展字段**:KeyUsage(用途:数字签名/加密)、ExtendedKeyUsage(服务器认证/客户端认证)、BasicConstraints(是否为 CA)……

> 关键认知:证书 = 公钥 + 身份声明 + CA 的签名。公钥是公开的,签名是防篡改的,身份声明是谁担保的——整个信任体系就建立在"CA 的签名可信"这一个假设上。

### 三种常见的证书内容陷阱

- 只写 CN 没写 SAN → 现代浏览器直接拒绝
- 通配符只覆盖一级:`*.example.com` 不匹配 `api.dev.example.com`
- 证书链不完整:只发了叶子证书,客户端补不全中间 CA → 部分客户端验证失败

## 02 PKI:信任是怎么传递的

### 根 CA、中间 CA 与叶子

```
你的浏览器信任库
 └── 根 CA(内置,如 ISRG Root X1)
      └── 中间 CA(Let's Encrypt 的 R10/R11)
           └── 叶子证书(你的 example.com)
```

信任传递规则:**只要链上的每一环都被上一环签名,整条链就都可信**。浏览器只需要验证叶子 → 中间 → 根,而根是它本来就信任的。

### 为什么需要中间 CA

直接让根 CA 签所有叶子证书不行:

- **根的私钥必须极度安全**(泄了等于整个互联网的信任崩塌),所以要离线保管、极少使用
- 根 CA 用私钥签中间 CA(一年几次),中间 CA 签叶子(一天几万次)——**把高频操作和最高机密分离**
- 出事故只吊销中间 CA,根不受影响

### 交叉签名与信任传递的延伸

历史上还有一个细节:Let's Encrypt 的根证书刚出现时,浏览器还不信任它,于是让 IdenTrust(老牌根)交叉签名它的中间证书——用户因为信任 IdenTrust,间接信任了 Let's Encrypt。**信任可以"借用"**,这就是 PKI 里交叉签名的价值。

### 证书透明度(CT):让"信任"可审计

CT 是一个公开账本:所有公共 CA 签发的证书都必须提交日志。好处:你能查到"有没有人冒充 example.com 申请过证书"——恶意签发的证书无处遁形。Chrome 已经强制要求新证书必须带 SCT(签名证书时间戳)。

## 03 一张证书是怎么签出来的

### 完整流程:密钥对 → CSR → CA 签名 → 下发

```
[申请方]                          [CA]
 1. 生成密钥对(私钥自留)
 2. 组装 CSR(公钥 + 身份信息)
 3. 提交 CSR ────────────────→
 4.                          验证申请者确实拥有域名
 5.                          用 CA 私钥签名 → 生成证书
 6.                    ←──── 下发证书
 7. 部署:证书(公开) + 私钥(保密)
```

**CSR(Certificate Signing Request)**是申请的关键中间物:它包含公钥和身份信息,由申请方用私钥签名——CA 看到 CSR 就知道"申请者确实持有对应私钥"。

```bash
# 生成密钥对 + CSR 一步到位
openssl req -new -newkey rsa:2048 -nodes \
  -keyout example.key -out example.csr \
  -subj "/CN=example.com"

# 查看 CSR 内容
openssl req -in example.csr -text -noout
```

### 申请方怎么证明"域名是我的"

CA 必须验证域名所有权,三种主流方式:

1. **HTTP-01**:CA 给一个随机 token,要求放到 `http://example.com/.well-known/acme-challenge/`,能访问到即证明控制权
2. **DNS-01**:要求添加一条 TXT 记录 `_acme-challenge.example.com`——适合通配符证书
3. **TLS-ALPN-01**:在 443 端口临时应答一个特殊握手

> 绿色提示:这三种验证方式的本质都是"**能控制这个域名的证明**"——能放文件、能改 DNS、能应答 443,都是控制权的证据。

## 04 吊销:证书的"后悔药"

### 证书为什么需要吊销

私钥泄露、域名易主、员工离职……证书在到期前就需要作废。但吊销机制有一个先天缺陷:**它依赖于客户端去查询**。

### CRL 与 OCSP

- **CRL(证书吊销列表)**:CA 定期发布一份"已吊销证书序列号"的黑名单,客户端下载后比对。缺点:列表越来越大、更新有延迟
- **OCSP(在线证书状态协议)**:客户端实时问 CA"这张证书吊销了吗",CA 回"好/坏"。缺点:每次握手多一次查询,查询通道还能被中间人拦截(于是有了 OCSP stapling——服务器代查,把结果"钉"进握手)

### 吊销的无奈现实

吊销并不完美,三个现实:

- **吊销滞后**:CRL 更新周期内(可能是 24h+),被盗证书依然被信任
- **OCSP 故障静默放行**:多数客户端在 OCSP 服务器挂了时选择"放行"(fail-open),而不是拒绝
- **移动端检查更松**:很多 APP 根本不查吊销

所以业界的应对不是"把吊销做得完美",而是:**证书短命 + 自动化轮换**(Let's Encrypt 的 90 天、SPIFFE 的小时级)。让"吊销"这个笨重的机制变得不那么必要。

## 05 公开信任:Let's Encrypt 与 ACME

### 为什么它是革命性的

在 Let's Encrypt 之前,HTTPS 证书要花钱买、流程人工、一年一签。Let's Encrypt 的贡献:

- **免费**:公共信任成本降为零
- **90 天有效期**:把"证书过期"变成常态事件,倒逼自动化
- **ACME 协议**:机器与 CA 对话的标准——自动申请、自动续期,全流程无人值守

### ACME 自动化流程(certbot 示例)

```bash
# 安装 certbot + nginx 插件
apt install certbot python3-certbot-nginx

# 申请并自动配置 nginx(HTTP-01 验证)
certbot --nginx -d example.com -d www.example.com

# 自动续期测试(90 天证书,默认 60 天续一次)
certbot renew --dry-run

# 续期后需要 reload nginx —— certbot 插件会自动做
```

### 生产自动化清单

- 续期任务跑定时(certbot renew 默认 systemd timer / crontab)
- 证书到期前 N 天告警(防续期任务静默失败)
- 通配符证书用 DNS-01(需要 DNS 服务商 API 权限)
- 多域名场景用 --nginx 插件自动 reload

## 06 私有信任:搭建内部 CA

### 为什么需要内部 CA

公共 CA 只签公网域名。内部服务(内网域名、IP、服务名、mTLS 客户端证书)需要自己的信任锚——这就是 mTLS 篇里"内部 PKI"的落地。

### 方案对比:三个工具

| 方案 | 适合 | 特点 |
| --- | --- | --- |
| 纯 openssl | 学习/演示 | 零依赖,全手动,易错 |
| easy-rsa | 小型团队 | OpenVPN 同款,证书目录结构清晰 |
| step-ca | 生产/自动化 | 自带 ACME 服务,短期证书,CLI 友好,与 SPIFFE 兼容 |

### 用 step-ca 十分钟起一个内部 CA

```bash
# 1. 初始化 CA(生成根密钥,交互设置密码)
step ca init --name "Internal CA" \
  --dns ca.internal.example.com \
  --address ":8443" \
  --provisioner admin

# 2. 把 CA 证书分发给需要信任它的机器/服务
step ca root ca.crt
# 信任 CA:Linux 放 /usr/local/share/ca-certificates/ 后 update-ca-certificates
# 或:nginx 在 ssl_client_certificate 里引用 ca.crt

# 3. 签发服务器证书(自动带 SAN)
step ca certificate example.internal.example.com server.crt server.key

# 4. 签发 mTLS 客户端证书
step ca certificate client-01 client.crt client.key

# 5. 命令行直接测试双向 TLS
step ca test --server example.internal.example.com:8443
```

### 内部 CA 的信任分发清单

- 服务器证书:各服务的 TLS 配置引用内部 CA 根
- 客户端证书:mTLS 场景发给调用方设备/服务
- **根 CA 私钥离线保管**(不放在任何服务器上),用密码加密
- 定期备份,但备份与私钥同样敏感

## 07 生命周期运维:签发 → 监控 → 轮换 → 吊销

### 监控:证书要"主动"盯

证书过期是静默事故之王。盯住三个时间点:

```bash
# 1. 本地证书到期天数
openssl x509 -in server.crt -noout -enddate
# notAfter=Sep  2 06:00:00 2027 GMT

# 2. 远程证书到期天数(对线上所有域名)
echo | openssl s_client -servername example.com \
  -connect example.com:443 2>/dev/null | \
  openssl x509 -noout -enddate

# 3. 扫全量:一个 shell 循环 + cron,到期前 30/7/1 天告警
for h in example.com api.example.com; do
  d=$(echo | openssl s_client -servername $h -connect $h:443 2>/dev/null \
      | openssl x509 -noout -enddate | cut -d= -f2)
  echo "$h → $d"
done
```

### 轮换:无感替换的三步

1. 新证书先行部署(nginx 支持原子 reload:`nginx -s reload`)
2. 验证新证书生效(`openssl s_client` 看新 notAfter)
3. 确认无误后,旧证书自然过期——**永远不要先删旧的**

mTLS 场景的轮换要两端协调(见 mTLS 篇 07 章):调用方先换,服务方后换。

### 私钥保管:安全下限

- 私钥文件权限 600,属主仅 root/服务账户
- 生产私钥优先入 KMS/HSM(云上 ALB/ACM 托管证书,私钥根本不落地)
- 私钥进 git/镜像 = 安全事件,CI 里加扫描
- 根 CA 私钥:离线 + 密码 + 多人保管(Shamir 拆分可选)

### 吊销操作

```bash
# 纯 openssl 场景:维护一个已吊销序列号列表
openssl ca -revoke client.crt        # 吊销
openssl ca -gencrl -out crl.pem      # 生成吊销列表
# 分发 CRL 或配置 OCSP 服务,客户端才会知道

# step-ca 场景
step ca revoke client.crt --reason "device compromised"
# step-ca 自动维护 CRL/OCSP
```

## 08 排障手册:证书问题三分钟定位

> 速查表是"看报错找解法";下面五个案例把表里每行**真实跑一遍**(现象/排查/修复/验证),输出来自 `TLS/labs` 实验环境(单容器 nginx 前端 1443→443,证书由自带 lab CA/中间 CA 签发)。命令在 `TLS/labs/` 下执行;若本机配了 HTTP 代理,curl 需加 `--noproxy '*'`。一键复现:`bash start.sh` + 对应场景脚本。

### 错误 → 原因 → 解法速查

| 客户端报错 | 根因 | 解法 |
| --- | --- | --- |
| certificate has expired | 过期 | 检查 notAfter,轮换 |
| self-signed certificate | 链里没有受信根 | 配完整链/装 CA |
| unable to get local issuer | 中间 CA 缺失 | ssl_certificate 拼完整链 |
| hostname/IP mismatch | SAN 不含域名/IP | 重签带 SAN |
| certificate verify failed(深层) | 链断裂/过期/吊销 | openssl verify 逐层查 |

### openssl 排障三连

```bash
# 1. 看证书内容(主体/有效期/SAN)
openssl x509 -in server.crt -noout -subject -issuer -dates
openssl x509 -in server.crt -noout -ext subjectAltName

# 2. 验证链是否完整可信任
openssl verify -CAfile ca-bundle.pem server.crt
# server.crt: OK   ← 这句是金标准

# 3. 看线上服务器实际发的证书(和配置对不上?多半是没 reload)
echo | openssl s_client -servername example.com \
  -connect example.com:443 -showcerts 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

### 案例一:certificate has expired(表第一行)

前端被换上一张 2024-09 就过期的证书,nginx 毫无意见,客户端先炸:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/ 2>&1 | head -2
curl: (60) SSL certificate problem: certificate has expired
```

排障三连走一遍——① 看证书内容,过期一目了然;② verify 报 error 10;③ 线上实发确认就是它:

```bash
$ openssl x509 -in certs/out/server-expired.crt -noout -subject -issuer -dates
subject=CN=www.example.com
issuer=CN=Lab Internal Root CA
notBefore=Sep  3 2024 GMT
notAfter=Sep  1 00:00:00 2024 GMT                      ← 过期(还发现 notBefore 晚于 notAfter)

$ openssl verify -CAfile certs/out/ca/lab-ca.crt certs/out/server-expired.crt
error 10 at 0 depth lookup: certificate has expired
error server-expired.crt: verification failed

$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null \
    | openssl x509 -noout -enddate
notAfter=Sep  1 00:00:00 2024 GMT                      ← 线上实发:确认无误
```

修复:换有效证书并 reload(见下方灵异事件一:换完必须 reload);验证以 `openssl verify` 的 **OK** 为金标准:

```bash
$ openssl verify -CAfile certs/out/ca/lab-ca.crt certs/out/server-www.crt
certs/out/server-www.crt: OK
```

> 复现脚本:`bash scenarios/08-1-expired.sh`。

### 案例二:self-signed certificate(表第二行)

前端被换成一站"野生"自签证书(自己签自己,和任何受信 CA 都没关系):

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/ 2>&1 | head -2
curl: (60) SSL certificate problem: self signed certificate
```

排障三连——① subject == issuer(自己签自己),铁证;② verify 报 error 18:

```bash
$ openssl x509 -in certs/out/server-selfsigned.crt -noout -subject -issuer
subject=CN=www.example.com
issuer=CN=www.example.com                              ← subject == issuer = 自签

$ openssl verify -CAfile certs/out/ca/lab-ca.crt certs/out/server-selfsigned.crt
error 18 at 0 depth lookup: self-signed certificate
```

修复:换上 lab CA 签发的正规证书并 reload;验证:`server-www.crt: OK` + curl 通过。

> 复现脚本:`bash scenarios/08-2-self-signed.sh`。常见变体:链里出现 error 19(self-signed in chain)——中间 CA 缺了,见案例三。

### 案例三:unable to get local issuer(表第三行)

证书由**中间 CA**(lab intermediate)签发,但 `ssl_certificate` 只填了叶子、没拼中间 CA:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/ 2>&1 | head -2
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

排障三连——① s_client -showcerts 数证书:只下发 1 张(缺中间);② verify error 20;③ 把中间 CA 塞进 -untrusted 再验:链其实是通的 → **问题在"下发不全"不在证书本身**:

```bash
$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -showcerts 2>/dev/null \
    | grep -c 'BEGIN CERTIFICATE'
1                                                 ← 只发了叶子

$ openssl verify -CAfile certs/out/ca/lab-ca.crt certs/out/server-chain-leaf.crt
error 20 at 0 depth lookup: unable to get local issuer certificate

$ openssl verify -CAfile certs/out/ca/lab-ca.crt \
       -untrusted certs/out/ca/intermediate.crt certs/out/server-chain-leaf.crt
certs/out/server-chain-leaf.crt: OK            ← 补上中间就通:证书没问题
```

修复:`ssl_certificate` 填 **叶子+中间CA 拼接**的完整链文件;验证:线上改为下发 2 张、curl 通过:

```bash
$ echo | openssl s_client ... -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE'
2                                                 ← 叶子+中间,客户端能补全链了
```

> 复现脚本:`bash scenarios/08-3-missing-issuer.sh`。这就是 Let's Encrypt 让你配 `fullchain.pem` 而不是 `cert.pem` 的原因。

### 案例四:hostname/IP mismatch(表第四行)

证书只有 CN、没有任何 SAN,用户用 IP(127.0.0.1)访问——CN 回退对 IP 无效,直接 mismatch:

```bash
$ curl --noproxy '*' --cacert certs/out/ca/lab-ca.crt https://127.0.0.1:1443/ 2>&1 | head -2
curl: (60) SSL: certificate subject name 'www.example.com' does not match target host name '127.0.0.1'
```

排障三连——① SAN 扩展一片空白;② verify 只看链(不看名字),**OK 不代表能访问**;③ 域名请求还能靠 CN 兼容蒙混(`-verify_hostname` 放行),但 IP 访问没有 CN 可回退:

```bash
$ openssl x509 -in certs/out/server-nosan.crt -noout -ext subjectAltName
No extensions in certificate                    ← 没有 SAN

$ openssl verify -CAfile certs/out/ca/lab-ca.crt certs/out/server-nosan.crt
certs/out/server-nosan.crt: OK                  ← 链没问题,但解决不了名字

$ echo | openssl s_client -connect 127.0.0.1:1443 -verify_hostname www.example.com \
       -CAfile certs/out/ca/lab-ca.crt 2>/dev/null | grep -i verification
Verification: OK                                ← 域名靠 CN 兼容放行(浏览器不会!)
```

修复:重签时把访问要用到的域名/IP 全部写进 SAN;验证:新证书 SAN 在、IP 访问恢复。

> 复现脚本:`bash scenarios/08-4-hostname-mismatch.sh`。要点:CN 兼容是"历史包袱",浏览器/严格库已去掉;排查"名字对不上"先 `-ext subjectAltName`。

### 案例五:深层 certificate verify failed(表第五行)

服务端**完整下发**了 叶子+中间,但调用方的信任锚配错了——只装了中间 CA、没装根:

```bash
$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com \
       -CAfile certs/out/ca/intermediate.crt 2>/dev/null | grep -iE 'verification' | head -1
Verification error: unable to get issuer certificate    # 客户端视角:error 21
```

排障三连——① -showcerts 确认服务器链发全了(2 张,排除案例三);② verify -verbose **逐层看断在哪一环**(error 2 at 1 depth = 断在中间 CA 之上);③ 换正确的根再验同一张叶子,链路健康 → 定位到**客户端信任配置**:

```bash
$ openssl verify -CAfile certs/out/ca/intermediate.crt -verbose certs/out/server-chain-leaf.crt
error 2 at 1 depth lookup: unable to get issuer certificate   # 深层断点:中间CA的签发者不可见

$ openssl verify -CAfile certs/out/ca/lab-ca.crt -untrusted certs/out/ca/intermediate.crt \
       certs/out/server-chain-leaf.crt
certs/out/server-chain-leaf.crt: OK                            # 换根来验:链是健康的
```

修复:客户端信任锚换成真正的根(`--cacert lab-ca.crt` / 系统信任库装根),服务器照旧下发完整链;验证 `Verification: OK`。

> 复现脚本:`bash scenarios/08-5-deep-chain-failure.sh`。要点:报错文案看不出断在哪一环,`openssl verify` 的 depth 数字 + `-verbose` 才是定位器。

### 灵异事件一:改了证书没生效

现象:证书+密钥换成了新签的(30 天有效期),**忘了 reload**——线上 s_client 看到的还是旧证书:

```bash
# 磁盘文件已是新的(notAfter=Oct 3 2026),线上下发的却是旧的(notAfter=Sep 3 2027):
$ openssl x509 -in certs/out/server-www.crt -noout -dates
notAfter=Oct  3 02:26:25 2026 GMT          ← 文件:新的

$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null \
    | openssl x509 -noout -dates
notAfter=Sep  3 02:26:25 2027 GMT          ← 线上:旧的!nginx 内存里还是老证书
```

排查:别信"我改过了",线上实测为准——s_client 显示的才是线上在用的证书。修复:reload:

```bash
$ docker exec tls-lab nginx -s reload -c /etc/nginx/lab/nginx.conf.gen
```

验证:同一命令,证书变成新的(notAfter=Oct 3 2026):

```bash
$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null \
    | openssl x509 -noout -dates
notAfter=Oct  3 02:26:25 2026 GMT          ← reload 后生效
```

> 复现脚本:`bash scenarios/08-6-ghost-reload.sh`。附注:若只换证书不换配套私钥,nginx reload 会直接报 `key values mismatch` 拒绝重载——这也是好事,至少不会带上错配证书上线。

### 灵异事件二:一个 IP 多证书串台

现象:同一台 443 上跑两个域名(www/other),新域名的 server 块没配上,它的 SNI 全落进默认 server(www),拿到的是 **www 的证书**:

```bash
$ curl --noproxy '*' --resolve other.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://other.example.com:1443/ 2>&1 | head -2
curl: (60) SSL: no alternative certificate subject name matches target host name 'other.example.com'

$ echo | openssl s_client -connect 127.0.0.1:1443 -servername other.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN=www.example.com                 ← 串台实锤:要 other 的证书,下来的是 www 的
```

排查:用 `-servername` 显式指定域名逐个测,看"该域名拿到谁的证书",再对照 nginx 443 的 server 块缺谁补谁:

```bash
$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN=www.example.com
$ echo | openssl s_client -connect 127.0.0.1:1443 -servername other.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN=www.example.com                 ← other 域名也拿到 www 证书
```

修复:给 other.example.com 补上自己的 server 块(server_name + 对应证书)并 reload;验证:SNI 分流正确、curl 通过:

```bash
$ echo | openssl s_client -connect 127.0.0.1:1443 -servername other.example.com 2>/dev/null \
    | openssl x509 -noout -subject
subject=CN=other.example.com               ← 各回各家

$ curl --noproxy '*' --resolve other.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://other.example.com:1443/
backend: xfp=[] xff=[] client_cn=[] client_verify=[]
```

> 复现脚本:`bash scenarios/08-7-ghost-sni-mixup.sh`。要点:IP 共用时证书与 SNI 是一一对应的;排障永远带 `-servername`,别用裸 IP 测多证书站点。

## 写在最后

把证书的一生串起来看,它就是一个**治理问题套着技术问题**:

- 技术上:证书 = 公钥 + 身份 + 签名,链到信任锚即可信
- 流程上:密钥对 → CSR → CA 验证域名 → 签名 → 下发 → 部署
- 治理上:过期要监控、泄露要吊销、私钥要保管、信任要审计(CT)

记住三个心法:**证书短命 + 自动化,胜过完美的吊销**;私钥保管是安全下限,监控是运维下限;`openssl verify` 的 OK 是唯一金标准,不信配置信实测。

---

📚 本系列共四篇,建议按①→④顺序阅读;系列总览见 [TLS 学习笔记](README.md):

**① [正向代理与反向代理详解](正向代理与反向代理详解.md)** —— 代理流向基础:谁站在客户端身边,谁站在服务器面前
**② [代理×TLS 深潜:终结、透传与桥接](代理×TLS-终结透传与桥接.md)** —— termination / passthrough / bridging,从握手到抓包
**③ [mTLS:从单向信任到双向互认](mTLS-从单向信任到双向互认.md)** —— 服务间认证,证书即身份
**④ [证书的那些事:从 CSR 到过期](证书的那些事-从CSR到过期.md)** —— PKI 体系、签发流程与生命周期运维

> 我是 {{作者名}},{{一句话简介}}。如果你觉得今天这篇有收获,欢迎**点赞、在看、转发**三连,我们下篇见。
