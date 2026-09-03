#!/usr/bin/env bash
# ②09 坑二:自签证书只写 CN 不写 SAN
# 运行:bash scenarios/09-2-cert-no-san.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "坑二:证书只写 CN 没写 SAN —— 本机工具全绿,Chrome 直接拒"
# ── 现象 ──
stage "现象"
echo "# 换上一张 CN=www.example.com 但没有 SAN 扩展的证书:"
WWW_CERT=server-nosan.crt WWW_KEY=server-nosan.key reload_conf
echo "# 本机的 curl(CN 兼容)依然畅通——你以为没问题:"
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/
echo "# 但现代浏览器(Chrome 58+)只认 SAN,CN 直接忽略 → NET::ERR_CERT_COMMON_NAME_INVALID"
echo "# 服务间调用若用强校验库(Go/Java 默认严格模式),同样直接拒绝"

# ── 排查 ──
stage "排查"
echo "# 看证书扩展区有没有 SAN(没有输出 = 没有 SAN 扩展):"
run openssl x509 -in "$C/server-nosan.crt" -noout -ext subjectAltName
echo "# 对比一张正常证书:"
run openssl x509 -in "$C/server-www.crt" -noout -ext subjectAltName

# ── 修复 ──
stage "修复"
echo "# 生成 CSR 时就要带上 SAN(-addext 或 extfile 二选一,示例用 addext):"
run openssl req -new -key "$C/server-nosan.key" -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:example.com,DNS:localhost,IP:127.0.0.1" \
  -out /tmp/nosan-fix.csr
run openssl x509 -req -in /tmp/nosan-fix.csr -CA "$C/ca/lab-ca.crt" -CAkey "$C/ca/lab-ca.key" \
  -CAcreateserial -days 365 -out /tmp/nosan-fix.crt \
  -copy_extensions copy >/dev/null && echo "签发完成(已 copy CSR 里的 SAN)"
# 装回去走正常路径(用现成的带 SAN 证书)
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf

# ── 验证 ──
stage "验证"
echo "# 新证书的 SAN 扩展在:"
run openssl x509 -in /tmp/nosan-fix.crt -noout -ext subjectAltName
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/

echo "# 结论:现代客户端只信 SAN;排查”证书能用又不能用“先看扩展区有没有 SAN 行。"
