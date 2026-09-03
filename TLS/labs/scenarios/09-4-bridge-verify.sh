#!/usr/bin/env bash
# ②09 坑四:后段 TLS 不校验证书(proxy_ssl_verify off)
# 运行:bash scenarios/09-4-bridge-verify.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
CA="certs/out/ca/lab-ca.crt"

section "坑四:Bridging 关了 proxy_ssl_verify —— 后端段等于明文裸奔"
echo "# 场景:443 前端以 bridging 方式代理到 https://api.example.com:9443(后端,"
echo "# 容器内解析到 127.0.0.1);后端故意换成一站自签证书(模拟攻击者/被冒名的后端)。"

# ── 现象 ──
stage "现象"
echo "# 配置 A:proxy_ssl_verify off —— 代理不校验后端证书,自签照单全收:"
FRAG_FRONT_LOC=front-bridge-verify-off
BACKEND_CERT=server-selfsigned.crt
BACKEND_KEY=server-selfsigned.key
reload_conf
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/
echo "# 一切正常?正常才可怕:此时后端网络里插一台假后端,流量照样被接走。"

# ── 排查 ──
stage "排查"
echo "# 翻 nginx 配置定位 proxy_ssl_verify:"
run grep -n "proxy_ssl_verify\|proxy_pass https" nginx/nginx.conf.gen

# ── 修复 ──
stage "修复"
echo "# 配置 B:proxy_ssl_verify on + 信任的后端 CA(信任的是 lab CA,后端却是自签):"
FRAG_FRONT_LOC=front-bridge-verify-on
reload_conf
echo "# 代理立刻拒绝自签后端:"
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/ -o /dev/null -w "http_code=%{http_code}\n"
echo "# nginx error log 里的真实原因:"
run docker logs "$CNAME" 2>&1 | grep -iE "upstream SSL certificate" | tail -1

# ── 验证 ──
stage "验证"
echo "# 配置 C:verify on + 后端换回 lab CA 签发的正规证书:"
BACKEND_CERT=server-api.crt
BACKEND_KEY=server-api.key
reload_conf
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/
echo "# 恢复默认:"
FRAG_FRONT_LOC=front-http-echo
BACKEND_CERT=server-api.crt
BACKEND_KEY=server-api.key
reload_conf

echo "# 结论:proxy_ssl_verify off 的省事只在演示里合理;生产必须 on + trusted_certificate。"
