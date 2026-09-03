#!/usr/bin/env bash
# ④08 排障 row4:hostname/IP mismatch(SAN 不含域名/IP)
# 运行:bash scenarios/08-4-hostname-mismatch.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "08-4 报错 hostname/IP mismatch —— 证书里没有用户访问的那个名字"
# ── 现象 ──
stage "现象"
echo "# 证书只有 CN=www.example.com,没有任何 SAN;用户用 IP(127.0.0.1)访问:"
WWW_CERT=server-nosan.crt WWW_KEY=server-nosan.key reload_conf
pipe "curl --noproxy '*' -sS --max-time 6 --cacert $CA https://127.0.0.1:1443/ 2>&1 | head -2"

# ── 排查:排障三连 ──
stage "排查:排障三连"
echo "# ① 看 SAN:扩展区一片空白:"
run openssl x509 -in "$C/server-nosan.crt" -noout -ext subjectAltName
echo "# ② verify 只看链,不看名字——它 OK 不代表能访问:"
run openssl verify -CAfile "$CA" "$C/server-nosan.crt"
echo "# ③ 域名请求还能靠 CN 兼容蒙混过关(-verify_hostname www 放行):"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -verify_hostname www.example.com -CAfile $CA 2>/dev/null | grep -iE 'verification' | head -1"
echo "#    但 IP 访问没有 CN 可回退——上面现象里的报错就是这么来的:"

# ── 修复 ──
stage "修复"
echo "# 重签:把访问要用到的域名/IP 全部写进 SAN(含 IP:127.0.0.1):"
echo '#   -addext "subjectAltName=DNS:www.example.com,DNS:example.com,DNS:localhost,IP:127.0.0.1"'
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf

# ── 验证 ──
stage "验证"
echo "# 新证书 SAN 在:"
run openssl x509 -in "$C/server-www.crt" -noout -ext subjectAltName
echo "# IP 访问恢复:"
pipe "curl --noproxy '*' -sS --max-time 6 --cacert $CA https://127.0.0.1:1443/"
