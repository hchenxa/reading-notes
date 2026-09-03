#!/usr/bin/env bash
# ③07 坑五:双向验证开了,后端没接身份(授权)
# 运行:bash scenarios/07-5-verify-not-consumed.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed && reload_conf
C="certs/out"
MTLS="curl -sk --max-time 6 https://127.0.0.1:8443/"

section "坑五:双向验证开了,后端没接身份 —— mTLS 成了昂贵的连接加密"
# ── 现象 ──
stage "现象"
echo "# 谁持证书都能进:nginx 校验了”证书有效“,但不过问”你是谁“。"
echo "# client-01(被授权的调用方):"
pipe "$MTLS --cert $C/client-alice.crt --key $C/client-alice.key"
echo "# client-02(别的服务,本不该访问支付服务):照样 200:"
pipe "$MTLS --cert $C/client-bob.crt --key $C/client-bob.key -w '\nhttp_code=%{http_code}\n'"

# ── 排查 ──
stage "排查"
echo '# 看后端有没有消费 nginx 透传的身份头($ssl_client_s_dn / $ssl_client_verify):'
echo '#   proxy_set_header X-Client-CN $ssl_client_s_dn;      ← 是否透传?'
echo '#   应用里是否校验 X-Client-CN / 做鉴权?                ← 是否消费?'
echo "# 上面两次请求回显里 client_verify 都是 SUCCESS,后端却一视同仁——问题不在 TLS,在授权层:"
run grep -n "X-Client" nginx/nginx.conf.gen | head -3

# ── 修复 ──
stage "修复"
echo "# 用证书身份做白名单:nginx 层先拦一道(map 只放行 CN=client-01):"
FRAG_AUTHZ_MAP=authz-map FRAG_AUTHZ_DENY=authz-deny-if reload_conf
echo '#   map $ssl_client_s_dn $authz { default 0; "~CN=client-01$" 1; }'
echo '#   server { ... if ($authz = 0) { return 403; } ... }'

# ── 验证 ──
stage "验证"
echo "# client-01:放行(200):"
pipe "$MTLS --cert $C/client-alice.crt --key $C/client-alice.key -w '\nhttp_code=%{http_code}\n'"
echo "# client-02:被拦(403):"
pipe "$MTLS --cert $C/client-bob.crt --key $C/client-bob.key -w '\nhttp_code=%{http_code}\n'"

echo "# 结论:verify_client 只回答”证书有效吗“,授权(谁可以进来)必须由应用/网关消费证书身份。"
