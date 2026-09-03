#!/usr/bin/env bash
# ②09 坑五:SNI 路由漏掉 default(ssl_preread map)
# 运行:bash scenarios/09-5-passthrough-no-default.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
CA="certs/out/ca/lab-ca.crt"

section "坑五:Passthrough 的 SNI map 漏写 default —— 未知域名无路可走"
# ── 现象 ──
stage "现象"
echo "# map 里只写了 api.example.com,没有 default;4443 上所有流量按 SNI 路由:"
FRAG_PASS_DEFAULT= reload_conf
run grep -n -A3 "map \$ssl_preread_server_name" nginx/nginx.conf.gen
echo "# 已知域名 api.example.com 正常;未知域名直接翻车:"
run curl --noproxy '*' -sS --max-time 6 --resolve api.example.com:4443:127.0.0.1 --cacert "$CA" https://api.example.com:4443/
run curl --noproxy '*' -sS --max-time 6 --resolve new-app.example.com:4443:127.0.0.1 --cacert "$CA" https://new-app.example.com:4443/ || echo "(curl 退出码 $?)"
echo '# nginx 侧的真实日志($backend 为空 → 无法路由):'
run docker logs "$CNAME" 2>&1 | tail -2

# ── 排查 ──
stage "排查"
echo "# 抓一把到 4443 的 ClientHello 看 SNI 是否真的发出了(new-app.example.com):"
pipe "echo | openssl s_client -connect 127.0.0.1:4443 -servername new-app.example.com 2>&1 | head -1"

# ── 修复 ──
stage "修复"
echo "# map 补一个 default 兜底(落到主力后端,至少不会直接断):"
echo "#   map \$ssl_preread_server_name \$backend {"
echo "#       api.example.com 127.0.0.1:9443;"
echo "#       default         127.0.0.1:9443;"
echo "#   }"
FRAG_PASS_DEFAULT=pass-default reload_conf

# ── 验证 ──
stage "验证"
echo "# 未知域名现在能连上了(注意:后端只持 api 的证书,严格校验仍会 mismatch——"
echo "# 兜底只解决路由,证书匹配是后端自己的事):"
run curl --noproxy '*' -skS --max-time 6 --resolve new-app.example.com:4443:127.0.0.1 https://new-app.example.com:4443/

echo "# 结论:没有 default 的 SNI 路由表 = 新域名上线即事故;兜底 + 上线前演练缺一不可。"
