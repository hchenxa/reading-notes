#!/usr/bin/env bash
# ④08 排障 row1:certificate has expired
# 运行:bash scenarios/08-1-expired.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"
WWW="--noproxy '*' --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/"

section "08-1 报错 certificate has expired —— 三步定位+修复"
# ── 现象 ──
stage "现象"
echo "# 前端换上一张 2024-09 就过期的证书:"
WWW_CERT=server-expired.crt WWW_KEY=server-expired.key reload_conf
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/ 2>&1 | head -2"

# ── 排查:排障三连 ──
stage "排查:排障三连"
echo "# ① 看证书内容(有效期一目了然):"
pipe "openssl x509 -in $C/server-expired.crt -noout -subject -issuer -dates"
echo "# ② openssl verify 验链:"
run openssl verify -CAfile "$CA" "$C/server-expired.crt"
echo "# ③ 看线上服务器实际发的证书:"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -enddate"

# ── 修复 ──
stage "修复"
echo "# 换回有效证书并 reload:"
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf

# ── 验证 ──
stage "验证"
echo "# 重跑 ②的金标准命令:server-www.crt: OK 才是验收线:"
run openssl verify -CAfile "$CA" "$C/server-www.crt"
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/"
