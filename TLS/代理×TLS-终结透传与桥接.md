# 代理 × TLS 深潜:握手、私钥与三条加密之路

> 上一版讲清了"是什么",这一版往底层挖:一次握手到底交换了什么?为什么代理持证就能"看见"你的流量?SSL 剥离怎么打?真实架构里三兄弟怎么组合?最后用 tcpdump 抓包,让流量自己开口说话。

## 01 握手:理解一切的钥匙

要真正理解 termination、passthrough、bridging,先理解一次 TLS 握手里发生了什么。所有三种模式的差异,本质上都是同一个问题:**是谁应答了 ClientHello**。

### 握手四步,一步都不能少

以 TLS 1.2 为例(1.3 在下面讲),客户端访问 `https://example.com`,握手是这样的:

STEP 01:客户端发出 ClientHello——带上**客户端随机数**、支持的密码套件列表(如 ECDHE-RSA-AES256-GCM)、以及**明文可见的 SNI**(客户端声明"我要访问 example.com")
STEP 02:服务器回 ServerHello——选定一个密码套件、发**服务器随机数**和**证书链**
STEP 03:客户端验证证书——链到受信根 CA、域名匹配 SAN、有效期、吊销状态,然后用证书里的公钥参与密钥交换
STEP 04:双方完成密钥交换,各自算出**同一把会话密钥**,之后的业务数据全部用对称加密(AES-GCM)收发,并互发 Finished 确认

> 关键认知:握手结束后,真正传输数据的密钥是**双方临时算出来的会话密钥**,而不是证书里的私钥。证书的作用是"证明我是我",会话密钥的作用是"我们悄悄说话"。这个区分,是理解后面一切攻击与防御的基础。

### 密钥交换:为什么现代 TLS 不用 RSA 静态交换

早期 TLS 用 RSA 密钥交换:客户端用服务器公钥加密一个随机数发过去,服务器用私钥解开。简单,但有一个致命伤——**没有前向保密(Forward Secrecy)**:

- 攻击者现在把流量录下来存着,以后偷到私钥,就能**解密历史流量**
- 现代 TLS 全部改用 **ECDHE(临时椭圆曲线 Diffie-Hellman)**:双方交换临时公钥,各自算出会话密钥,临时私钥用后即焚
- 前向保密的意义:即使私钥泄露,已抓到的历史流量依然无法解密

> 一句话亮点:私钥是"身份证",ECDHE 是"对暗号"——暗号每场对话重新对,身份证丢了也只影响以后。

### 证书链:根 CA、中间 CA 与叶子证书

一张证书不是孤立的。浏览器验证证书时,会沿链向上走:**叶子证书(服务器自己的)→ 中间 CA 证书 → 根 CA 证书**。根 CA 预置在系统的信任库里,中间 CA 由根签发。任何一个环节断裂,验证失败。

三个高频概念:

1. **SAN(Subject Alternative Name)**:证书里声明的域名列表,浏览器校验域名匹配就是比对它。自签证书最常见的坑是只写了 CN 没写 SAN,现代浏览器直接不认
2. **OCSP stapling**:证书吊销状态的查询方式之一——由服务器(或代理)代浏览器去查,把结果"钉"在握手里,省一次往返
3. **证书有效期**:Let's Encrypt 把证书压到 90 天,就是要让"证书过期"变成常态事件,逼自动化运维

### TLS 1.2 vs 1.3:三次变化

TLS 1.3 不是小修小补:

1. **更快的握手**:1.2 最多两个来回(2-RTT),1.3 首次握手一个来回(1-RTT),重连直接 0-RTT
2. **砍掉不安全能力**:移除 RSA 静态密钥交换、移除全部弱密码套件(3DES、RC4),密套列表从几十个缩到五个
3. **SNI 加密(ECH)**:1.3 里 SNI 仍然明文;但 ECH(Encrypted Client Hello)扩展可以把整个 ClientHello 加密——**这是 passthrough 模式的生存威胁**:如果 ECH 普及,代理连"看到哪个域名"都做不到,SNI 路由将失效,只能按 IP/端口路由

> 绿色提示:面试如果被问"TLS 1.3 有什么新特性",就答这三条:1-RTT 握手、强制前向保密、ECH 加密握手。前两条已经落地,第三条正在路上。

## 02 三兄弟的本质:谁应答了 ClientHello

现在重新看三个概念,一秒钟分辨:

**TLS Termination**:代理应答 ClientHello、出示自己的证书、持有私钥 → 代理是 TLS 的终点,后端收到明文
**TLS Passthrough**:代理不应答,把 ClientHello 原样转发,后端应答 → 后端是 TLS 的终点,代理只是搬运工
**TLS Bridging**:代理应答前一段,然后以"客户端"身份再发一个 ClientHello 给后端 → 两段握手,两个终点

> 图1:三种模式的握手终点

```
Termination:  [客户端] ──握手──> [代理:应答握手·持私钥] ──明文──> [后端]
Passthrough:  [客户端] ──握手──> [代理:转发握手] ──握手──> [后端:应答·持私钥]
Bridging:     [客户端] ──握手1──> [代理:应答·再发起握手2] ──握手2──> [后端:应答·持私钥]
```

观察一个深层事实:**持私钥的一方,掌握对全部明文的控制权**。代理持证,代理就能读、改、缓存、审计一切;这就是 termination 的"权力"来源,也是它的风险来源——**谁持证,谁就是你的流量管理员**。

### 三种模式对"流量"的三种视角

| 视角 | Termination | Passthrough | Bridging |
| --- | --- | --- | --- |
| 明文 | 全可见 | 不可见 | 代理内部可见,链路不可见 |
| 可路由信息 | 一切(路径/Header/内容) | 仅 SNI + 端口 | 一切 |
| 可改写的 | 一切(改内容都行) | 无 | 一切 |
| 私钥风险面 | 集中在代理 | 分散在后端 | 两处 |

## 03 Termination 深潜:权力的代价

### 配置与四个"加分项"

基础配置上篇讲过,这里补四个生产必做项:

```nginx
server {
    listen       443 ssl;
    server_name  www.example.com;
    http2 on;   # HTTP/2:握手后在一条连接上多路复用

    ssl_certificate     /etc/nginx/certs/server.crt;   # 完整证书链
    ssl_certificate_key /etc/nginx/certs/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;   # 会话复用,省握手
    ssl_stapling on;                      # OCSP stapling,省证书查询
    ssl_stapling_verify on;

    add_header Strict-Transport-Security "max-age=31536000" always;  # HSTS
    # 强制客户端走 HTTPS,防 SSL 剥离(见 06 章)

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

四个加分项的作用:

1. **会话复用(ssl_session_cache)**:TLS 握手是全流程最贵的部分(两次 RSA/ECDHE 运算 + 证书链验证)。缓存会话票据后,重连直接 1-RTT 甚至 0-RTT,吞吐量翻倍很常见
2. **OCSP stapling**:代理替所有客户端去查证书吊销状态,省掉每个客户端一次的额外查询,还防止查询通道被劫持
3. **HSTS**:强制浏览器以后只走 HTTPS——这是防 SSL 剥离的第一道闸(06 章细讲)
4. **http2 on**:TLS 之上的 HTTP/2 多路复用,一个连接并发请求,延迟大降

### 权力推演:私钥泄露会发生什么

假设代理的私钥泄露(日志泄露、容器镜像被翻、内网横向渗透):

- 攻击者拿到私钥,可以**冒充你的站点**:对用户做钓鱼,证书校验照样通过
- 如果配置里还残存 RSA 静态交换(或 TLS 1.0),攻击者可以**解密已抓取的历史流量**
- 攻击者控制代理 = 控制全部流量明文:它不再需要解密,它本来就在明文侧

> 踩坑提示:私钥文件的权限、备份、轮换,是 termination 部署的"地下工程"——别把精力全花在证书申请上,私钥保管才是安全下限。

### 什么时候不要用 termination

- 后端服务要求**端到端完整性**(如支付回调验签依赖原始数据)——代理改一个字节,签名就废
- 你**无法信任内网**(跨公网转发)——明文段会暴露
- 证书管理想**分散**(合规要求每个服务独立持证)

## 04 Passthrough 深潜:隧道管理员的边界

### ssl_preread 到底做了什么

Nginx 的 `ssl_preread` 模块在 **TCP 层预读** TLS 握手的前几个字节:ClientHello 的长度字段和 SNI 扩展,拿来做 `map` 路由,然后立刻把字节流交还给双向转发——**它从未参与握手,也从未拿到任何密钥**。

```nginx
stream {
    map $ssl_preread_server_name $backend {
        api.example.com    192.168.1.10:8443;
        www.example.com    192.168.1.11:8443;
        default            192.168.1.10:8443;
    }
    server {
        listen      443;
        proxy_pass  $backend;
        ssl_preread on;
    }
}
```

### 前向保密在这里是"自带的"

passthrough 模式下,代理**没有私钥、没有会话密钥、连握手都不参与**——这意味着:

- 历史流量即使被完整抓取,解密它需要的是**后端**的私钥和会话数据,和代理无关
- 代理被攻破,攻击者拿到的是"一段看不懂的字节流记录",不是明文
- 这就是为什么高安全边界场景(金融内网、跨机构互联)偏爱 passthrough

### 它的三个痛点

1. **路由粒度只有一个字段**:SNI 之外,代理对请求一无所知,灰度、A/B、按 Header 分流全部做不了
2. **ECH 的威胁**:TLS 1.3 ECH 一旦普及,SNI 也看不见了,L4 SNI 路由整体失效
3. **会话状态全在客户端与后端**:代理无法干预握手参数,弱协议(如果后端开 TLS 1.0)它拦不住

> 绿色提示:判断一个 LB 是 L4 还是 L7,一句话就够了——"它看得到 URL 吗?"看得到是 L7(能 termination),只看得到端口/SNI 是 L4(passthrough)。

## 05 Bridging 深潜:两段加密与 mTLS

### 配置回顾与三个细节

```nginx
location / {
    proxy_pass https://backend.example.internal:8443;
    proxy_ssl_server_name on;
    proxy_ssl_verify on;                          # 生产必开
    proxy_ssl_trusted_certificate /etc/nginx/certs/backend-ca.crt;
    proxy_ssl_session_reuse on;
}
```

三个细节:

1. **proxy_ssl_verify 是安全下限**:关了它,代理到后端这段等于裸奔(攻击者在后端网络里插一台假后端就能接走流量)
2. **proxy_ssl_server_name on**:代理作为"客户端"发起握手时也要带 SNI,后端按 SNI 选证书
3. **session reuse**:代理到后端是一条高频长连接,复用会话能省掉每请求一次握手

### mTLS:双向出示证书

Bridging 可以升级为 **mTLS(双向 TLS)**——不仅代理验证后端的证书,后端也验证代理的证书:

```nginx
# 代理侧:既校验后端,也出示自己的客户端证书
location / {
    proxy_pass https://backend.example.internal:8443;
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/nginx/certs/backend-ca.crt;
    proxy_ssl_certificate     /etc/nginx/certs/proxy-client.crt;
    proxy_ssl_certificate_key /etc/nginx/certs/proxy-client.key;
}
```

mTLS 的意义:**身份验证从"单向信任"变成"双向互认"**。只有持有合法客户端证书的代理才能访问后端——这是微服务网格、内网 PKI 的基石,也是"零信任"架构里最常用的一招。

## 06 攻防:私钥、中间人与降级

这一章,把安全视角拉满——攻击者怎么打,你就知道怎么防。

### 攻击一:SSL 剥离(SSL Stripping)

攻击者在客户端和真实服务器之间插入自己,把页面里的 `https://` 链接改成 `http://`,客户端如果没察觉,就以明文发起请求——攻击者在明文侧全收。

**防御:HSTS**。服务器用 `Strict-Transport-Security` 头告诉浏览器:"未来 max-age 秒内,只准走 HTTPS"。浏览器记住后,剥离攻击失效。所以 HSTS 不是可选项,是 termination 的必选项。

### 攻击二:中间人(MITM)与"企业版 MITM"

经典 MITM:攻击者拦截连接、冒充服务器出示自己的证书——浏览器校验失败,报警。

但有一个合法的 MITM:公司/学校的 HTTPS 审计网关。原理是**你的设备信任了公司下发的内部 CA**:

1. 公司给所有员工设备预装公司自签根 CA
2. 审计网关对"example.com"出示一张由该 CA 签发的证书
3. 浏览器校验链:叶子 → 公司 CA → 信任库,**校验通过**
4. 网关解密 → 审计 → 重新加密 → 转发给真实站点

> 关键认知:所谓"企业能不能看到我的 HTTPS 流量",本质不是技术问题,而是**信任问题**——你的设备信任了谁的 CA,谁就能终止你的 TLS。这和 termination 是同一个机制:审计网关就是持证的"代理"。

### 攻击三:降级攻击

攻击者干扰握手,逼迫客户端与服务器用旧协议(TLS 1.0)或弱密码套件(3DES、RC4),然后暴力破解或利用已知漏洞。

**防御**:`ssl_protocols TLSv1.2 TLSv1.3` + 白名单式密码套件,不给降级留空间。

### 攻击四:CRIME / BREACH

利用压缩率的侧信道:数据压缩后,密文变短;攻击者反复构造请求,通过"压缩后更短"推断出明文(如 Cookie 里的会话令牌)。TLS 层压缩早已默认禁用,HTTP 层压缩(BREACH)需要应用层配合,比如 CSRF token 随机化。

### 攻击五:会话恢复攻击

会话票据(Session Ticket)如果被偷,攻击者可以重放票据冒充客户端。**防御**:定期轮换 ticket 密钥(`ssl_session_ticket_key`),票据有效期设短。

### 攻击六:私钥泄露

见 03 章推演——现代 ECDHE 保证历史流量安全,但冒充站点、控制明文仍然成立。**防御**:私钥最小权限、定期轮换、硬件密钥(HSM)、监控私钥异常使用。

> 一句话亮点:加密解决的是"偷听",证书解决的是"冒充",HSTS 解决的是"降级",mTLS 解决的是"谁在敲门"——每一层防一种攻击,少一层就漏一类。

## 07 真实架构:三兄弟的组合拳

现实世界里,三兄弟很少单独出现。看三个真实架构。

### 架构一:云 LB + 内网 Nginx(终止 + 桥接)

最常见的生产 Web 架构:

```
[公网用户] ──TLS──> [云LB:终止,持证书] ──明文/内网──> [Nginx集群:桥接,重新加密] ──TLS──> [后端:持证]
```

**为什么这么组合**:
- 云 LB 做 termination:海量握手由云厂商的 LB 承担,性能瓶颈不在你;证书管理在 LB 一处
- 内网 Nginx 做 bridging:内网也不是绝对可信(有内部威胁模型),代理到后端重新加密,防内网嗅探
- 后端持证:微服务之间还能做 mTLS,内网 PKI 顺理成章

### 架构二:微服务网格(入口终止 + 网格 mTLS)

Istio 这类服务网格的标准姿势:

```
[公网] ──TLS──> [Ingress Gateway:终止] ──mTLS──> [Sidecar] ──mTLS──> [Sidecar] ──> [服务A]
                                                    └──mTLS──> [Sidecar] ──> [服务B]
```

**为什么这么组合**:
- 入口 Gateway termination:对外一个域名、一张证书、一套 WAF
- 服务间全部 mTLS:每个 Pod 的 Sidecar 双向证书互认——就算攻破一个 Pod,横向移动也要过证书这关
- 这不是"追求花哨",而是把 bridging 的"重新加密"升级成"双向互认"的完整体系

### 架构三:CDN 回源(边缘终止 + 回源桥接)

```
[用户] ──TLS──> [CDN边缘节点:终止+缓存] ──TLS回源──> [源站:持证]
```

**为什么这么组合**:
- CDN 边缘必须 termination:它要缓存静态资源,必须看到内容;终止在边缘,还能就近加解密
- 回源必须 bridging:CDN 到自己源站的链路跨运营商、跨地域,不能裸奔;`proxy_ssl_verify on` 保证源站不被假 CDN 冒认
- 代价:CDN 厂商可见你的明文——选 CDN 本质是选信任对象

> 绿色提示:所有架构都在回答同一个问题——"每一段链路的信任边界画在哪"。终止放哪,信任边界就在哪;加密到哪,信任就延伸到哪。

## 08 抓包实操:让流量开口说话

前几章的原理,这一章全部用抓包验证。环境:本机 Nginx + openssl + tcpdump(Linux 用 `lo`,macOS 用 `lo0`,下文以 lo0 为例)。

### 实验一:看 ClientHello 里的 SNI 明文

先起一个 termination 的 Nginx(监听 8443),然后抓包:

```bash
# 终端1:抓 ClientHello,过滤 TLS 握手扩展里的 server_name
sudo tshark -i lo0 -f "tcp port 8443" \
  -Y "tls.handshake.extensions_server_name" \
  -T fields -e tls.handshake.extensions_server_name

# 终端2:发起请求
curl -k https://127.0.0.1:8443/ -s >/dev/null

# 终端1输出(明文可见!):
# example.com
```

**结论**:SNI 作为唯一的明文信息,在握手第一步就暴露——这就是 passthrough 路由的唯一依据,也是 ECH 要解决的事。

### 实验二:对比三种模式的握手终点

同一台机器,三个监听:8443(termination)、443(passthrough 到 8443)、8444(后端 TLS)。逐个用 openssl 验证:

```bash
# termination:证书是代理签发的
openssl s_client -connect 127.0.0.1:8443 -servername example.com \
  </dev/null 2>/dev/null | grep -E "subject=|issuer="

# passthrough:证书是"后端"签发的——握手根本没经过代理
openssl s_client -connect 127.0.0.1:443 -servername example.com \
  </dev/null 2>/dev/null | grep -E "subject=|issuer="

# 加上 -state 看握手阶段,对比两边的流程
openssl s_client -connect 127.0.0.1:8443 -servername example.com -state </dev/null 2>&1 | head -20
```

`-state` 会打印握手状态机:`CONNECTED → client hello → server hello → ... → SSL negotiation finished`。对比 passthrough 时你会发现——代理的 443 上**根本不会出现握手状态**,它只是搬运字节。

### 实验三:抓包看 termination 的明文段

```bash
# 终端1:抓后端 8080 端口的流量
sudo tcpdump -i lo0 -A port 8080 2>/dev/null | grep -a "GET /"

# 终端2:通过代理访问
curl -k https://127.0.0.1:8443/ -s >/dev/null

# 终端1输出:明文 HTTP 请求!GET / HTTP/1.1
```

**结论**:同样一次 HTTPS 访问,公网段全是密文,代理后段全是明文——图 1 里那条"明文 HTTP"标签,是可以在抓包里亲眼看到的。

### 实验四:验证 X-Forwarded-Proto 的传递

```bash
# 后端收下代理转发的头(用 curl 模拟或起个打印 header 的小服务)
curl -k https://127.0.0.1:8443/ -v 2>&1 | grep -i "forwarded"
# 后端视角: X-Forwarded-Proto: https, X-Forwarded-For: 127.0.0.1
```

> 绿色提示:抓包三连就是本节浓缩——**看 SNI 用 tshark,看握手终点用 s_client -state,看明文段用 tcpdump -A**。这三招能验证你遇到的任何一个 TLS 代理问题。

## 09 常见坑(升级版)

> 这一章每个坑都配了**真实复现**:现象、排查、修复、验证四步,输出全部来自 `TLS/labs` 实验环境(单容器 nginx:443 前端 / 8443 mTLS / 9443 TLS 后端 / 4443 passthrough / 8080 echo 后端,证书由自带 lab CA 签发)。命令都在 `TLS/labs/` 目录下执行;若本机配了 HTTP 代理,curl 需加 `--noproxy '*'`。一键复现:先 `bash start.sh`,再跑对应场景脚本。

### 坑一:证书过期,线上静默炸掉

Nginx 对过期证书不报警,客户端却开始报 `certificate has expired`。证书监控要自动化,Let's Encrypt 的 90 天设计就是逼你自动化。

**现象**:给 443 前端换上一张 2024-09 就已过期的证书,reload 成功、`nginx -t` 也没有任何过期告警——**静默**;但客户端一握手就翻车:

```bash
$ docker exec tls-lab nginx -t -c /etc/nginx/lab/nginx.conf.gen
nginx: the configuration file /etc/nginx/lab/nginx.conf.gen syntax is ok
nginx: configuration file /etc/nginx/lab/nginx.conf.gen test is successful   ← 没有过期告警

$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
curl: (60) SSL certificate problem: certificate has expired
```

**排查**:服务器不报警,只能主动查——本地文件与线上实发分别看(不信配置,信 s_client):

```bash
$ openssl x509 -in certs/out/server-expired.crt -noout -enddate
notAfter=Sep  1 00:00:00 2024 GMT          ← 本地文件:一年前就过期了

$ echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null \
    | openssl x509 -noout -subject -enddate
subject=CN=www.example.com
notAfter=Sep  1 00:00:00 2024 GMT          ← 线上实发:同一张,确认没被其他 server 块顶掉
```

**修复**:换回有效证书并 reload(换证书≠改配置,reload 必须做,见④篇的"灵异事件一")。

**验证**:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
backend: xfp=[https] xff=[192.168.127.1] client_cn=[] client_verify=[]
```

> 复现脚本:`bash scenarios/09-1-cert-expired.sh`。要点:nginx 不会替你盯到期时间,到期监控(30/7/1 天告警)要自己做。

### 坑二:自签证书只写 CN 不写 SAN

现代浏览器(Chrome 58+)校验 SAN,CN 直接忽略。`openssl req` 生成时要么加 `-addext "subjectAltName=..."`,要么用配置文件。

**现象**:换上 CN=www.example.com 但**没有任何 SAN 扩展**的证书后,本机 curl(CN 兼容)照样通——**你以为没问题,其实问题最阴**:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
backend: xfp=[https] xff=[192.168.127.1] client_cn=[] client_verify=[]
# ↑ 本机工具全绿;但 Chrome 58+ 直接 NET::ERR_CERT_COMMON_NAME_INVALID,
#   Go/Java 等强校验库(默认严格模式)同样直接拒绝
```

**排查**:看证书扩展区有没有 SAN——没有输出就是没有 SAN 扩展:

```bash
$ openssl x509 -in certs/out/server-nosan.crt -noout -ext subjectAltName
No extensions in certificate                                        ← 问题证书:一片空白

$ openssl x509 -in certs/out/server-www.crt -noout -ext subjectAltName
X509v3 Subject Alternative Name:
    DNS:www.example.com, DNS:example.com, DNS:localhost, IP Address:127.0.0.1
```

**修复**:生成 CSR 时就带 SAN(`-addext` 与 extfile 二选一):

```bash
$ openssl req -new -key certs/out/server-nosan.key -subj "/CN=www.example.com" \
    -addext "subjectAltName=DNS:www.example.com,DNS:example.com,DNS:localhost,IP:127.0.0.1" \
    -out /tmp/nosan-fix.csr
```

**验证**:重签的证书 SAN 扩展在,服务恢复:

```bash
$ openssl x509 -in /tmp/nosan-fix.crt -noout -ext subjectAltName
X509v3 Subject Alternative Name:
    DNS:www.example.com, DNS:example.com, DNS:localhost, IP Address:127.0.0.1
```

> 复现脚本:`bash scenarios/09-2-cert-no-san.sh`。要点:CLI 工具的 CN 兼容会骗你;排查"证书能用又不能用"先看扩展区有没有 SAN 行。

### 坑三:Termination 忘了 X-Forwarded-Proto

后端收到请求却不知道客户端走的是 HTTPS,生成 http 开头的跳转——回调、登录态、防盗链全部错。termination 必配 X-Forwarded-Proto + X-Forwarded-For。

**现象**:location 只写了 `proxy_pass http://127.0.0.1:8080;`,没有透传任何转发头。用户明明走 https,后端(8080 echo)收到的 X-Forwarded-Proto 是**空的**:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
backend: xfp=[] xff=[] client_cn=[] client_verify=[]              ← xfp 空!后端以为你在走 http
```

**排查**:在后端打日志/起 echo 接口看收到的头;或在代理层 `curl -v` 看请求头里有没有转发头:

```bash
# (请求头里没有任何 X-Forwarded-Proto —— 后端更不可能有,问题定位在代理层)
```

**修复**:location 里补上两条 `proxy_set_header`:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header X-Forwarded-Proto $scheme;                    # ← 加上
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;   # ← 加上
}
```

**验证**:同样一个请求,后端现在看得到 https:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
backend: xfp=[https] xff=[192.168.127.1] client_cn=[] client_verify=[]
```

> 复现脚本:`bash scenarios/09-3-xfp-missing.sh`。要点:termination 是后端唯一的信息源,转发头必配。

### 坑四:后段 TLS 不校验证书

Bridging 里 `proxy_ssl_verify off` 等于给中间人开门。生产必须 on + `proxy_ssl_trusted_certificate`。

**现象**:前端以 bridging 代理到 `https://api.example.com:9443`,后端被换成**自签证书**(模拟攻击者/被冒名的后端),`proxy_ssl_verify off` 时自签照单全收:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
backend: xfp=[] xff=[] client_cn=[] client_verify=[]
# 一切正常?正常才可怕:后端网络里插一台假后端,流量照样被接走
```

**排查**:翻 nginx 配置定位 `proxy_ssl_verify`:

```bash
$ grep -n "proxy_ssl_verify\|proxy_pass https" nginx/nginx.conf.gen
33:            proxy_pass https://api.example.com:9443;
34:            proxy_ssl_verify off;                                ← 元凶
```

**修复**:改成 on + 信任的后端 CA。代理立刻拒绝自签后端(502):

```nginx
location / {
    proxy_pass https://api.example.com:9443;
    proxy_ssl_verify on;                                           # ← 打开
    proxy_ssl_trusted_certificate /etc/nginx/certs/ca/lab-ca.crt;  # ← 信任 lab CA
    proxy_ssl_server_name on;
}
```

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/ -o /dev/null -w '%{http_code}\n'
502
# nginx error log 里的真实原因:
# [error] upstream SSL certificate verify error: (18:self-signed certificate)
#         while SSL handshaking to upstream, upstream: "https://127.0.0.1:9443/"
```

**验证**:后端换回 lab CA 签发的正规证书,verify on 下恢复 200:

```bash
$ curl --noproxy '*' --resolve www.example.com:1443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://www.example.com:1443/
backend: xfp=[] xff=[] client_cn=[] client_verify=[]
```

> 复现脚本:`bash scenarios/09-4-bridge-verify.sh`(三段配置:off→on+自签→on+正规,逐段验证)。

### 坑五:SNI 路由漏掉 default

Passthrough 的 map 没写 default,未知域名直接连不上(客户端表现为连接被重置/空应答)。路由表一定要有兜底。

**现象**:stream 的 map 只写了 api.example.com,没有 default:

```nginx
map $ssl_preread_server_name $backend {
    api.example.com 127.0.0.1:9443;    # ← 没有 default 行
}
```

已知域名正常;新上线的域名(SNI=new-app.example.com)直接翻车:

```bash
$ curl --noproxy '*' --resolve api.example.com:4443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://api.example.com:4443/
backend: xfp=[] xff=[] client_cn=[] client_verify=[]              # 已知域名:通

$ curl --noproxy '*' --resolve new-app.example.com:4443:127.0.0.1 \
       --cacert certs/out/ca/lab-ca.crt https://new-app.example.com:4443/
curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL                  # 未知域名:连接被重置

# nginx error log 里的真实原因($backend 为空 → 无 upstream 可发):
# [error] no host in upstream "", client: ..., server: 0.0.0.0:4443
```

**排查**:抓一把到 4443 的 ClientHello,确认 SNI 真的发出了(发出了就是路由表的问题):

```bash
$ echo | openssl s_client -connect 127.0.0.1:4443 -servername new-app.example.com 2>&1 | head -1
Connecting to 127.0.0.1
```

**修复**:map 补 `default` 兜底(落到主力后端,至少不断连):

```nginx
map $ssl_preread_server_name $backend {
    api.example.com 127.0.0.1:9443;
    default         127.0.0.1:9443;    # ← 兜底
}
```

**验证**:未知域名能连上了——注意兜底只解决路由,后端证书匹配是后端自己的事(严格校验仍会 mismatch):

```bash
$ curl --noproxy '*' -k --resolve new-app.example.com:4443:127.0.0.1 https://new-app.example.com:4443/
backend: xfp=[] xff=[] client_cn=[] client_verify=[]
```

> 复现脚本:`bash scenarios/09-5-passthrough-no-default.sh`。要点:没有 default 的 SNI 路由表 = 新域名上线即事故。

### 坑六:密码套件白名单不放行 TLS 1.3

只写 `ssl_ciphers` 没写 `ssl_conf_command Ciphersuites`——TLS 1.3 的套件和 1.2 是**两套独立配置**,1.2 的白名单根本管不到 1.3。

**现象**:ssl_ciphers 只放行 AES-GCM,没配 1.3 的 Ciphersuites。TLS 1.2 段白名单生效;但 TLS 1.3 客户端主动点名 CHACHA20,照样协商成功:

```bash
$ openssl s_client -connect 127.0.0.1:1443 -servername www.example.com \
       -CAfile certs/out/ca/lab-ca.crt -tls1_2 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher is'
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384             # 1.2:白名单生效(AES 系)

$ openssl s_client -connect 127.0.0.1:1443 -servername www.example.com \
       -CAfile certs/out/ca/lab-ca.crt -tls1_3 \
       -ciphersuites TLS_CHACHA20_POLY1305_SHA256 </dev/null 2>&1 | grep -E 'Protocol|Cipher is'
New, TLSv1.3, Cipher is TLS_CHACHA20_POLY1305_SHA256           # 1.3:白名单根本没被约束!
```

**排查**:看 1.3 实际协商出的套件,和 ssl_ciphers 列表对照:

```bash
$ openssl s_client -connect 127.0.0.1:1443 -servername www.example.com \
       -CAfile certs/out/ca/lab-ca.crt -tls1_3 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher is'
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
```

**修复**:补上 1.3 段(Ciphersuites 只放行 AES-GCM):

```nginx
ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384';                 # TLS 1.2
ssl_conf_command Ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384;           # TLS 1.3 ← 补这行
```

**验证**:再点名 CHACHA20 → 服务器没有共同套件,握手直接失败(alert 40);点名白名单内的 AES-256-GCM → 正常:

```bash
$ openssl s_client ... -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 </dev/null 2>&1 | grep -iE 'error|Cipher' | head -2
error:0A000410:SSL routines:ssl3_read_bytes:ssl/tls alert handshake failure:...:SSL alert number 40
New, (NONE), Cipher is (NONE)

$ openssl s_client ... -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher is'
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
```

> 复现脚本:`bash scenarios/09-6-ciphers-tls13.sh`。要点:1.2 看 `ssl_ciphers`,1.3 看 `ssl_conf_command Ciphersuites`,两段都要管。

### 坑七:会话票据密钥不轮换

`ssl_session_ticket_key` 长期不换,泄露一次等于泄露一段时间内的会话。加个定时轮换任务。

**现象**:同一把密钥用了一年。正常情况会话恢复一切正常(Reused),你看不出任何问题:

```bash
# 建会话、存票据:
$ printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:1443 \
    -servername www.example.com -CAfile certs/out/ca/lab-ca.crt -tls1_2 \
    -sess_out /tmp/session.txt 2>/dev/null | grep -E '^New|^Reused'
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384

# 用票据重连 → Reused,会话恢复:
$ printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client -connect 127.0.0.1:1443 \
    -servername www.example.com -CAfile certs/out/ca/lab-ca.crt -tls1_2 \
    -sess_in /tmp/session.txt 2>/dev/null | grep -E '^New|^Reused'
Reused, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384
```

**排查**:密钥文件存在多久了?配置里有没有轮换痕迹:

```bash
$ ls -la certs/out/ticket.key
-rw-r--r--  80 ... certs/out/ticket.key      # 一把钥匙用到底,没有任何轮换记录

$ grep -n ssl_session_ticket_key nginx/nginx.conf.gen
31:        ssl_session_ticket_key /etc/nginx/certs/ticket.key;
```

**修复**:生成新钥匙换下旧钥匙并 reload(生产建议双钥匙交替:新的加密、旧的留作解密过渡一段):

```bash
$ openssl rand -out certs/out/ticket2.key 80     # 新钥匙(nginx 要求 80 字节)
```

**验证**:轮换后用**旧钥匙签发的票据**重连 → 无法解密,退回完整握手 New;新钥匙下重建会话 → Reused 恢复:

```bash
# 旧票据(轮换前签的)→ New:必须完整握手,旧会话作废
$ printf 'GET / HTTP/1.0\r\n\r\n' | openssl s_client ... -sess_in /tmp/session.txt 2>/dev/null | grep -E '^New|^Reused'
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384

# 新钥匙重建 + 复用 → Reused
New, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384
Reused, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384
```

> 复现脚本:`bash scenarios/09-7-ticket-key-rotation.sh`。要点:泄露的旧钥匙不会自动失效,定时轮换(如每月)才能让历史会话票据自然作废。

## 写在最后

回到开头的坐标:**谁应答 ClientHello,谁就是 TLS 的终点;谁持有私钥,谁就掌握流量明文的控制权**。

Termination 是把权力交给代理(换来七层能力,承担私钥风险);Passthrough 是把权力留给后端(换来干净边界,接受路由贫血);Bridging 是两段权力分置(最稳,也最重)。攻防那一章要记住的不是每个攻击的名字,而是**每一层防御都在回答"信任边界画在哪"**;架构那一章的每一个组合,都是这个问题的工程答案。

抓包是理解这一切的最后一步:当你在 tshark 里亲眼看到 SNI 明文、在 s_client -state 里看到握手终点、在 tcpdump -A 里看到明文 HTTP——这些名词就不再是名词,而是你排查问题时的直觉。

---

📚 本系列共四篇,建议按①→④顺序阅读;系列总览见 [TLS 学习笔记](README.md):

**① [正向代理与反向代理详解](正向代理与反向代理详解.md)** —— 代理流向基础:谁站在客户端身边,谁站在服务器面前
**② [代理×TLS 深潜:终结、透传与桥接](代理×TLS-终结透传与桥接.md)** —— termination / passthrough / bridging,从握手到抓包
**③ [mTLS:从单向信任到双向互认](mTLS-从单向信任到双向互认.md)** —— 服务间认证,证书即身份
**④ [证书的那些事:从 CSR 到过期](证书的那些事-从CSR到过期.md)** —— PKI 体系、签发流程与生命周期运维

> 我是 {{作者名}},{{一句话简介}}。如果你觉得今天这篇有收获,欢迎**点赞、在看、转发**三连,我们下篇见。
