#!/usr/bin/env bash
# ④08 灵异事件一:改了证书没生效(忘 reload)
# 运行:bash scenarios/08-6-ghost-reload.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "灵异事件一:改了证书没生效 —— 不信配置,信 s_client 实测"
# ── 现象 ──
stage "现象"
echo "# 运维把证书+密钥换成了新签的(30 天有效期的 server-www2),但忘了 reload:"
run cp "$C/server-www.crt" /tmp/server-www.crt.bak
run cp "$C/server-www.key" /tmp/server-www.key.bak
run cp "$C/server-www2.crt" "$C/server-www.crt"
run cp "$C/server-www2.key" "$C/server-www.key"
echo "# 看线上实际下发的证书——还是旧的(notAfter=一年后)?!"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -dates"
echo "# 磁盘上的文件已经是新的了(30 天有效期),但 nginx 内存里还是旧证书:"
pipe "openssl x509 -in $C/server-www.crt -noout -dates"

# ── 排查 ──
stage "排查"
echo "# 别信"我改过了",线上实测为准——s_client 显示的就是线上在用的证书:"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -dates"

# ── 修复 ──
stage "修复"
run docker exec "$CNAME" nginx -s reload -c /etc/nginx/lab/nginx.conf.gen

# ── 验证 ──
stage "验证"
echo "# reload 后同一命令:证书变成新的(notAfter=30 天后):"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -dates"
echo "# 收尾:还原默认证书+密钥并 reload:"
run cp /tmp/server-www.crt.bak "$C/server-www.crt"
run cp /tmp/server-www.key.bak "$C/server-www.key"
run docker exec "$CNAME" nginx -s reload -c /etc/nginx/lab/nginx.conf.gen
