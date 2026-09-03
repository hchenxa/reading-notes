#!/usr/bin/env bash
# ②09 坑六:密码套件白名单只写了 TLS 1.2,管不住 TLS 1.3
# 运行:bash scenarios/09-6-ciphers-tls13.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
CA="certs/out/ca/lab-ca.crt"
S="openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -CAfile $CA"

section "坑六:ssl_ciphers 只配了 1.2,1.3 的 Ciphersuites 忘配 —— 白名单形同虚设"
# ── 现象 ──
stage "现象"
echo "# 配置 A:ssl_ciphers 只放行 AES-GCM(1.2 段),没配 ssl_conf_command Ciphersuites:"
FRAG_CIPHERS=ciphers-12-aes-only reload_conf
echo "# TLS 1.2 客户端:白名单生效,只能协商出 AES-GCM:"
pipe "$S -tls1_2 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher is'"
echo "# TLS 1.3 客户端主动点名 CHACHA20:照样协商成功 → 1.3 段根本没被白名单约束!"
pipe "$S -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 </dev/null 2>&1 | grep -E 'Protocol|Cipher is'"

# ── 排查 ──
stage "排查"
echo "# 一条命令看 1.3 实际协商出的套件;对照 ssl_ciphers 列表,发现漏网之鱼:"
pipe "$S -tls1_3 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher is'"

# ── 修复 ──
stage "修复"
echo "# 补上 1.3 段:ssl_conf_command Ciphersuites ...(和 1.2 是两套独立配置):"
echo "#   ssl_ciphers 'ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384';"
echo "#   ssl_conf_command Ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384;"
FRAG_CIPHERS=ciphers-12-13-aes-only reload_conf

# ── 验证 ──
stage "验证"
echo "# 再点名 CHACHA20 → 服务器没有共同套件,握手直接失败:"
pipe "$S -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 </dev/null 2>&1 | grep -iE 'error|alert|Cipher is' | head -2"
echo "# 点名白名单内的 AES-256-GCM → 正常协商:"
pipe "$S -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384 </dev/null 2>/dev/null | grep -E 'Protocol|Cipher is'"

echo "# 结论:1.2 看 ssl_ciphers,1.3 看 ssl_conf_command Ciphersuites,两段都要管。"
