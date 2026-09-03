#!/usr/bin/env bash
# ④08 排障 row3:unable to get local issuer(链没发全)
# 运行:bash scenarios/08-3-missing-issuer.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "08-3 报错 unable to get local issuer —— 服务器只发了叶子,没发中间 CA"
echo "# 场景:证书由 中间CA(lab intermediate)签发,客户端只信任根(lab root)。"
# ── 现象 ──
stage "现象"
echo "# ssl_certificate 只填了叶子证书(server-chain-leaf.crt),没拼中间 CA:"
WWW_CERT=server-chain-leaf.crt WWW_KEY=server-chain-leaf.key reload_conf
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/ 2>&1 | head -2"

# ── 排查:排障三连 ──
stage "排查:排障三连"
echo "# ① 线上只下发了一张证书(缺中间,客户端找不到 issuer):"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE'"
echo "# ② verify 提示 error 20:"
run openssl verify -CAfile "$CA" "$C/server-chain-leaf.crt"
echo "# ③ 本地把中间 CA 补进 -untrusted 再验:链其实是通的 → 问题在"下发不全":"
run openssl verify -CAfile "$CA" -untrusted "$C/ca/intermediate.crt" "$C/server-chain-leaf.crt"

# ── 修复 ──
stage "修复"
echo "# ssl_certificate 填 叶子+中间CA 拼接的完整链(server-chain-full.crt):"
WWW_CERT=server-chain-full.crt WWW_KEY=server-chain-leaf.key reload_conf

# ── 验证 ──
stage "验证"
echo "# 线上现在下发 2 张证书,客户端能补全链:"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE'"
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/"
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf   # 恢复默认
