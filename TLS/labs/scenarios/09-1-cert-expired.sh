#!/usr/bin/env bash
# ②09 坑一:证书过期,线上静默炸掉
# 运行:bash scenarios/09-1-cert-expired.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "坑一:证书过期,线上静默炸掉 —— nginx 不报警,客户端开始报错"

# ── 现象 ──
stage "现象"
echo "# 把 443 前端的证书换成一张已经过期(notAfter=2024-09-01)的证书,reload 成功:"
WWW_CERT=server-expired.crt WWW_KEY=server-expired.key reload_conf
echo "# 事后单独跑配置检查,nginx 依然毫无意见(关键:没有任何过期告警):"
run docker exec "$CNAME" nginx -t -c /etc/nginx/lab/nginx.conf.gen
echo "# 客户端一握手就翻车:"
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/

# ── 排查 ──
stage "排查"
echo "# 服务器不报警,要主动查证书的过期时间——本地文件与线上实发分别看:"
run openssl x509 -in "$C/server-expired.crt" -noout -enddate
echo "# 线上实际下发的证书(不信配置,信这条命令):"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -subject -enddate"

# ── 修复 ──
stage "修复"
echo "# 换回未过期的 server-www.crt 并 reload:"
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf

# ── 验证 ──
stage "验证"
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com 2>/dev/null | openssl x509 -noout -enddate"

echo "# 结论:nginx 不会替你盯着过期时间,到期监控要自己做(到期前 30/7/1 天告警)。"
