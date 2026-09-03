#!/usr/bin/env bash
# ③07 坑二:服务端证书忘记 SAN
# 运行:bash scenarios/07-2-server-no-san.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"
MTLS="curl --cert $C/client-alice.crt --key $C/client-alice.key"

section "坑二:给 mTLS 服务签的证书忘写 SAN —— 严格模式的客户端全拒"
# ── 现象 ──
stage "现象"
echo "# 8443 的服务器证书换成只有 CN(www.example.com)、没有 SAN 的那张:"
WWW_CERT=server-nosan.crt WWW_KEY=server-nosan.key reload_conf
echo "# 走 www.example.com 访问,本机 curl(CN 兼容)照样通——以为没事:"
pipe "$MTLS --noproxy '*' -skS --max-time 6 --resolve www.example.com:8443:127.0.0.1 https://www.example.com:8443/"
echo "# 但现代浏览器 / 强校验库(Go、Java 默认只认 SAN)会直接拒——证书”能用“是假象"

# ── 排查 ──
stage "排查"
echo "# 看服务端证书扩展区,SAN 扩展为空:"
run openssl x509 -in "$C/server-nosan.crt" -noout -ext subjectAltName
echo "# 对比正常证书(3 个 DNS + 1 个 IP):"
run openssl x509 -in "$C/server-www.crt" -noout -ext subjectAltName

# ── 修复 ──
stage "修复"
echo "# 回到③04 章的同款签发姿势:CA 签名时 extfile 里的 SAN 行不能省:"
echo '#   openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \\'
echo '#     -CAcreateserial -days 365 -out server.crt \\'
echo '#     -extfile <(echo "subjectAltName=DNS:www.example.com,DNS:localhost,IP:127.0.0.1")'
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf

# ── 验证 ──
stage "验证"
run openssl x509 -in "$C/server-www.crt" -noout -ext subjectAltName
echo "# 服务恢复可用:"
pipe "$MTLS --noproxy '*' -skS --max-time 6 --resolve www.example.com:8443:127.0.0.1 https://www.example.com:8443/"

echo "# 结论:SAN 不是可选配置;自签证书把 SAN 写进签发流程,和 CSR 一样是默认动作。"
