#!/usr/bin/env bash
# ③07 坑一:客户端证书过期,所有调用方一起 400
# 运行:bash scenarios/07-1-client-cert-expired.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed && reload_conf
C="certs/out"
MTLS="curl -k --max-time 6 https://127.0.0.1:8443/"

section "坑一:客户端证书过期,所有调用方一起 400/握手失败"
# ── 现象 ──
stage "现象"
echo "# 一台消费方的客户端证书在 2024-09-01 就过期了,它还在照常调用:"
run openssl x509 -in "$C/client-expired.crt" -noout -subject -dates
echo "# 服务端(8443,ssl_verify_client on)直接拒绝:"
pipe "$MTLS --cert $C/client-expired.crt --key $C/client-expired.key -o /dev/null -w 'http_code=%{http_code}\n'"
echo '# nginx 访问日志里的 $ssl_client_verify 状态(FAILED 一目了然):'
pipe "docker logs $CNAME 2>&1 | grep -E 'FAILED|400' | tail -2"

# ── 排查 ──
stage "排查"
echo "# 先确认是”证书“问题而不是”没带证书“:两张都试:"
echo "#   A. 干脆不带证书 → 400(No required SSL certificate)"
pipe "$MTLS -o /dev/null -w 'no-cert: http_code=%{http_code}\n'"
echo "#   B. 过期证书 → 同样 400,但 nginx 日志里能看出 verify=FAILED"
echo "# 再看证书本身过期时间:"
run openssl x509 -in "$C/client-expired.crt" -noout -enddate

# ── 修复 ──
stage "修复"
echo "# 根因:签发时有效期设得太长又没盯到期。正确姿势:短命证书(如 90 天)"
echo "# + 到期前自动化续签,客户端先灰度换新证书、等旧的自然过期,再统一切:"
echo "#   curl --cert client-new.crt --key client-new.key https://...   ← 先换新证"
echo "#   服务端与监控确认新证全部生效后,再让旧的过期"

# ── 验证 ──
stage "验证"
echo "# 换上有交期的客户端证书,立即可用:"
pipe "$MTLS --cert $C/client-alice.crt --key $C/client-alice.key"
echo "# 服务端视角:SUCCESS:"
pipe "docker logs $CNAME 2>&1 | grep SUCCESS | tail -1"

echo "# 结论:客户端证书也有有效期;mTLS 轮换要两端协调,一刀切=全线 400。"
