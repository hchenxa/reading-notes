#!/usr/bin/env bash
# ④08 排障 row2:self-signed certificate
# 运行:bash scenarios/08-2-self-signed.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "08-2 报错 self-signed certificate —— 信任链里没有受信根"
# ── 现象 ──
stage "现象"
echo "# 前端被换成一站"野生"自签证书(自己签自己,不是任何受信 CA 发的):"
WWW_CERT=server-selfsigned.crt WWW_KEY=server-selfsigned.key reload_conf
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/ 2>&1 | head -2"

# ── 排查:排障三连 ──
stage "排查:排障三连"
echo "# ① 看证书内容:issuer 就是它自己(self-signed),和 lab CA 没半点关系:"
pipe "openssl x509 -in $C/server-selfsigned.crt -noout -subject -issuer"
echo "# ② verify:error 18 self-signed certificate:"
run openssl verify -CAfile "$CA" "$C/server-selfsigned.crt"
echo "# ③ s_client 看线上实发:issuer 仍是自己:"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -issuer"

# ── 修复 ──
stage "修复"
echo "# 用 lab CA 签发的正规证书换下它:"
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf

# ── 验证 ──
stage "验证"
echo "# 金标准:server-www.crt: OK + curl 通过:"
run openssl verify -CAfile "$CA" "$C/server-www.crt"
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/"
