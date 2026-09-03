#!/usr/bin/env bash
# ③07 坑三:吊销滞后 —— 被盗证书在 CRL 更新周期内依然有效
# 运行:bash scenarios/07-3-revocation-lag.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "坑三:吊销滞后 —— client-revoked 已被吊销,但它依然能通过验证"
# ── 现象 ──
stage "现象"
echo "# 这张客户端证书在 CA 侧已被吊销(index.txt 里标了 R):"
run grep -E "^R" "$C/ca/index.txt"
echo "# 但校验方如果不主动查 CRL,它照样 OK——吊销形同虚设:"
run openssl verify -CAfile "$CA" "$C/client-revoked.crt"

# ── 排查 ──
stage "排查"
echo "# 带上 CA 发布的 CRL 再验,立刻现形(certificate revoked):"
run openssl verify -CAfile "$CA" -CRLfile "$C/ca/lab-ca.crl" -crl_check "$C/client-revoked.crt"
echo "# 这就是”吊销滞后“:CRL 一天一更,被盗证书在窗口期内一直是”有效“的:"
run openssl crl -in "$C/ca/lab-ca.crl" -noout -lastupdate -nextupdate

# ── 修复 ──
stage "修复"
echo "# 三个缓解手段(注意 nginx 的 ssl_client_certificate 本身不查 CRL/OCSP):"
echo "#   1. 客户端证书短命(如 90 天)+ 到期前自动重签——吊销窗口自然收敛"
echo "#   2. 有条件的场景上 OCSP stapling / 服务端自行 CRL 校验"
echo "#   3. 泄露即上报:吊销动作本身要快。下面用同款 lab CA 的独立索引,"
echo "#      现签一张一次性客户端证书再吊销,看真实过程:"
D="$C/_revoke-demo"; rm -rf "$D"; mkdir -p "$D"
cp "$C/ca/lab-ca.crt" "$C/ca/lab-ca.key" "$D/"
touch "$D/index.txt"; echo 1000 > "$D/serial"
cat > "$D/ca.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir            = $D
database       = \$dir/index.txt
new_certs_dir  = \$dir
serial         = \$dir/serial
certificate    = \$dir/lab-ca.crt
private_key    = \$dir/lab-ca.key
default_md     = sha256
policy         = policy_any
copy_extensions = copy
unique_subject = no
default_crl_days = 365
[ policy_any ]
commonName      = supplied
EOF
run openssl genrsa -out "$D/leak.key" 2048 2>/dev/null
run openssl req -new -key "$D/leak.key" -subj "/CN=leaked-client" \
  -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=clientAuth" \
  -out "$D/leak.csr"
run openssl ca -batch -notext -config "$D/ca.cnf" -days 365 -in "$D/leak.csr" -out "$D/leak.crt" 2>/dev/null
echo "# 发现泄露,立刻吊销:"
run openssl ca -batch -config "$D/ca.cnf" -revoke "$D/leak.crt" 2>/dev/null
echo "# 吊销后重发 CRL 并验证:"
run openssl ca -batch -config "$D/ca.cnf" -gencrl -out "$D/lab-ca.crl" 2>/dev/null
run openssl verify -CAfile "$D/lab-ca.crt" -CRLfile "$D/lab-ca.crl" -crl_check "$D/leak.crt"
rm -rf "$D"

# ── 验证 ──
stage "验证"
echo "# 定期用 -crl_check 扫全部客户端证书(把这条命令加进巡检):"
run openssl verify -CAfile "$CA" -CRLfile "$C/ca/lab-ca.crl" -crl_check "$C/client-alice.crt"
run openssl verify -CAfile "$CA" -CRLfile "$C/ca/lab-ca.crl" -crl_check "$C/client-revoked.crt"

echo "# 结论:吊销是被动的”后悔药“,滞后窗口客观存在;短命证书+自动化才是主动解药。"
