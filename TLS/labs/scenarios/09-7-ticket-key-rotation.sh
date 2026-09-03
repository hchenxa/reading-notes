#!/usr/bin/env bash
# ②09 坑七:会话票据密钥(ssl_session_ticket_key)不轮换
# 运行:bash scenarios/09-7-ticket-key-rotation.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed && reload_conf   # 先回到默认状态(单把 ticket.key)
CA="certs/out/ca/lab-ca.crt"
S="openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -CAfile $CA -tls1_2"
SESS=/tmp/tls-lab-session.txt
REQ="GET / HTTP/1.0"

section "坑七:会话票据密钥长期不换 —— 泄露一次,泄露一段时间的会话"
# ── 现象 ──
stage "现象"
echo "# 同一把 ssl_session_ticket_key 用了一年:密钥可以解密期内所有历史会话票据。"
echo "# 先建立一次会话并保存票据:"
pipe "printf '$REQ\r\n\r\n' | $S -sess_out $SESS 2>/dev/null | grep -E '^New|^Reused'"
echo "# 立即用这张票据重连 → Reused:会话恢复成功:"
pipe "printf '$REQ\r\n\r\n' | $S -sess_in $SESS 2>/dev/null | grep -E '^New|^Reused'"

# ── 排查 ──
stage "排查"
echo "# 排查点:密钥文件存在多久了?配置里有没有轮换的痕迹:"
run ls -la certs/out/ticket.key
run grep -n "ssl_session_ticket_key" nginx/nginx.conf.gen

# ── 修复 ──
stage "修复"
echo "# 轮换:生成新钥匙,换下旧钥匙并 reload(生产建议双钥匙交替,留一把旧的过渡):"
run openssl rand -out certs/out/ticket2.key 80
TICKET_KEY=ticket2.key reload_conf

# ── 验证 ──
stage "验证"
echo "# 拿刚才(旧钥匙签发的)票据重连 → 无法解密,退回完整握手 New:"
pipe "printf '$REQ\r\n\r\n' | $S -sess_in $SESS 2>/dev/null | grep -E '^New|^Reused'"
echo "# 新钥匙下重新建会话并复用 → Reused 恢复:"
pipe "printf '$REQ\r\n\r\n' | $S -sess_out $SESS 2>/dev/null | grep -E '^New|^Reused'"
pipe "printf '$REQ\r\n\r\n' | $S -sess_in $SESS 2>/dev/null | grep -E '^New|^Reused'"

echo "# 结论:给 ssl_session_ticket_key 上个定时轮换任务(如每月),泄露的旧钥匙自然作废。"
