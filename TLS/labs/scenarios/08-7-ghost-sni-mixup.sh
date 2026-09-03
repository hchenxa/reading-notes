#!/usr/bin/env bash
# ④08 灵异事件二:一个 IP 多证书串台(SNI 路由)
# 运行:bash scenarios/08-7-ghost-sni-mixup.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "灵异事件二:一个 IP 多个证书串台 —— 别的域名拿到了 www 的证书"
echo "# 场景:同一台 443 上跑两个域名(www.example.com / other.example.com),各自证书。"
# ── 现象 ──
stage "现象"
echo "# 新域名的 server 块没加上(或 server_name 拼错),nginx 把它的请求全落进了"
echo "# 默认 server(www)→ other 拿到的是 www 的证书 → mismatch:"
FRAG_EXTRA_443_SERVER= reload_conf
pipe "curl --noproxy '*' -sS --max-time 6 --resolve other.example.com:1443:127.0.0.1 --cacert $CA https://other.example.com:1443/ 2>&1 | head -2"
echo "# s_client 看得更清楚:SNI=other.example.com,下来的却是 CN=www.example.com:"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername other.example.com 2>/dev/null | openssl x509 -noout -subject"

# ── 排查 ──
stage "排查"
echo "# 用 -servername 显式指定域名逐个测,看"该域名拿到的是谁的证书":"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -subject"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername other.example.com 2>/dev/null | openssl x509 -noout -subject"
echo "# 对照 nginx 443 的 server 块,缺谁补谁:"
run grep -n -A2 "server_name" nginx/nginx.conf.gen

# ── 修复 ──
stage "修复"
echo "# 给 other.example.com 补上自己的 server 块(server_name + 对应证书):"
FRAG_EXTRA_443_SERVER=extra-server-other reload_conf
run grep -n -B1 -A1 "other.example.com" nginx/nginx.conf.gen | head -8

# ── 验证 ──
stage "验证"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername other.example.com 2>/dev/null | openssl x509 -noout -subject"
pipe "curl --noproxy '*' -sS --max-time 6 --resolve other.example.com:1443:127.0.0.1 --cacert $CA https://other.example.com:1443/"
