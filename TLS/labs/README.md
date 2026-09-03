# TLS labs:可复现实验环境

三篇文章「常见坑 / 排障」章节里贴的**所有命令输出都来自这里**——本机 OpenSSL + 单容器 nginx,一键拉起、逐个场景复现,输出可对照、可重跑。

## 环境要求与快速开始

- 依赖:`docker`(任意引擎)、`openssl`(3.x)、`bash`
- 拉起:`bash TLS/labs/start.sh`(首次自动渲染默认 nginx 配置并启动容器)
- 跑单个场景:`bash TLS/labs/scenarios/<场景>.sh`,输出同时写入 `TLS/labs/out/<场景>.txt`
- 停止:`bash TLS/labs/stop.sh`
- 重新生成证书物料:`bash TLS/labs/certs/generate.sh`(会清空重签;**跑完必须重启容器**:`bash start.sh`,因为容器挂载的是生成目录,目录被重建后挂载会失效)

> 若本机配置了 HTTP 代理,curl 请加 `--noproxy '*'`(场景脚本里已内置)。

## 拓扑(单容器,host 端口)

```
本机                                     nginx 容器(tls-lab)
┌─────────────┐  1443→443   ┌────────────────────────────────┐
│ curl/openssl│────────────▶│ 443  termination 前端(www)      │
│             │  8443→8443  │ 8443 mTLS 前端(example.com)     │
│             │────────────▶│ 9443 TLS 后端(api)              │
│             │  4443→4443  │ 4443 stream passthrough         │
│             │────────────▶│ 8080 http echo 后端(自环)       │
└─────────────┘             └────────────────────────────────┘
  证书:labs/certs/out/          容器内 /etc/nginx/certs(只读挂载)
  配置模板:labs/nginx/          nginx 配置片段:nginx/nginx.conf.gen(由模板渲染)
```

- 8080 容器内自环 echo:回显它收到的 `X-Forwarded-Proto/X-Forwarded-For/客户端证书身份` 头,用于演示"后端视角"
- 9443 容器内 TLS 后端用域名 `api.example.com`(容器内 `/etc/hosts` 指向 127.0.0.1),保证 bridging 的 SNI 语义真实
- 证书物料(全部由内置 **lab CA** 签发,`certs/generate.sh` 一键生成):好证书、**过期证书**、**无 SAN 证书**、**自签证书**、**中间 CA 链**(叶子/完整链)、两张客户端证书、**已吊销证书 + CRL**、session ticket key

## 场景 ↔ 文档对照

| 文档章节 | 场景脚本(相对 `TLS/labs/`) | 复现什么 |
|---|---|---|
| ②09 坑一 | `scenarios/09-1-cert-expired.sh` | 过期证书静默加载、客户端报错、修复前后 |
| ②09 坑二 | `scenarios/09-2-cert-no-san.sh` | 只写 CN 不写 SAN:CLI 全绿但证书废了 |
| ②09 坑三 | `scenarios/09-3-xfp-missing.sh` | Termination 忘配 X-Forwarded-Proto |
| ②09 坑四 | `scenarios/09-4-bridge-verify.sh` | proxy_ssl_verify off→on 三段对比(含 502+error log) |
| ②09 坑五 | `scenarios/09-5-passthrough-no-default.sh` | ssl_preread map 缺 default → no host in upstream |
| ②09 坑六 | `scenarios/09-6-ciphers-tls13.sh` | ssl_ciphers 管不到 TLS 1.3 Ciphersuites |
| ②09 坑七 | `scenarios/09-7-ticket-key-rotation.sh` | 会话票据密钥轮换:Reused → New → Reused |
| ③07 坑一 | `scenarios/07-1-client-cert-expired.sh` | 客户端证书过期,调用方全线 400 |
| ③07 坑二 | `scenarios/07-2-server-no-san.sh` | mTLS 服务端证书忘写 SAN |
| ③07 坑三 | `scenarios/07-3-revocation-lag.sh` | 吊销滞后:± -crl_check 对比 + 真实吊销过程 |
| ③07 坑四 | `scenarios/07-4-key-in-git.sh` | 私钥进 git:构造事故→检出→移除→证明历史残留 |
| ③07 坑五 | `scenarios/07-5-verify-not-consumed.sh` | 验证开了没做授权:CN 白名单 200/403 |
| ③07 坑六 | `scenarios/07-6-test-uses-prod-ca.sh` | 测试环境信任生产 CA:审计→整改→复检 |
| ④08 案例一~五 | `scenarios/08-1-expired.sh` ~ `08-5-deep-chain-failure.sh` | 五种证书报错:expired / self-signed / 缺链 / mismatch / 深层断链 |
| ④08 灵异一 | `scenarios/08-6-ghost-reload.sh` | 换了证书没 reload:s_client 实测前后对比 |
| ④08 灵异二 | `scenarios/08-7-ghost-sni-mixup.sh` | 一个 IP 多证书 SNI 串台:补 server 块前后 |

## 实现说明

- **配置**:`nginx/nginx.conf.tpl` 是唯一模板,`#@FRAG:xxx@` 行按场景展开为 `nginx/fragments/<选中片段>.conf`,`@TOKEN@`(证书路径等)逐个替换 → 生成 `nginx/nginx.conf.gen` 挂载进容器,场景切换 = 换配置片段 + `nginx -s reload`
- **输出为真**:场景脚本只跑真实命令;文档里的输出片段与 `out/*.txt` 一一对应
- **已知环境细节**:
  - 容器挂载目录被重建(重跑 generate.sh)后必须重启容器,否则挂载句柄失效
  - macOS 自带 git 在部分 filter-branch 场景下行为异常,故 07-4 演示移除→证明历史残留,并给出 filter-repo 作为生产工具
  - TLS 1.3 下本环境 nginx 不回复 NewSessionTicket,票据演示统一用 `-tls1_2`
