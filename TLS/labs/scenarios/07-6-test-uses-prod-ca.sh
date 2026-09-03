#!/usr/bin/env bash
# ③07 坑六:测试环境也用"真 CA"
# 运行:bash scenarios/07-6-test-uses-prod-ca.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
D="out/_audit-demo"

section "坑六:测试环境信任生产 CA —— 测试证书在生产被"意外信任"的温床"
# ── 现象 ──
stage "现象"
echo "# 事故现场:测试环境 nginx 的 ssl_client_certificate 直接抄了生产配置,"
echo "# 信任的是生产 CA bundle:"
rm -rf "$D"; mkdir -p "$D"
printf '# 测试环境 nginx(错误示范:抄生产)\nserver {\n    listen 8443 ssl;\n    ssl_client_certificate /etc/pki/prod/ca-bundle.pem;  # ← 生产 CA!\n    ssl_verify_client on;\n}\n' > "$D/test-nginx-prod-ca.conf"
printf '# 正确示范:独立测试 CA\nserver {\n    listen 8443 ssl;\n    ssl_client_certificate /etc/nginx/certs/ca/lab-ca.crt;\n    ssl_verify_client on;\n}\n' > "$D/test-nginx-test-ca.conf"
run cat "$D/test-nginx-prod-ca.conf"
echo "# 危害:测试环境签的”测试证书“,因为测试机信任生产 CA,在生产网络里也能通过校验——"
echo "# 边界从此模糊;一旦测试私钥泄露,等于拿到半张生产门禁卡。"

# ── 排查 ──
stage "排查"
echo "# 审计:把所有环境配置里的信任 CA 全捞出来,看有没有混用:"
run grep -rn "ssl_client_certificate\|ssl_trusted_certificate" "$D" nginx/fragments/ certs/out/ca/lab-ca.crt 2>/dev/null | grep -v "certs/out/ca" | sed "s|$PWD/||"
echo "# 命中”生产字样/生产路径“的测试配置 = 必须整改:"
run grep -rn "prod" "$D"

# ── 修复 ──
stage "修复"
echo "# 环境隔离三件套:"
echo "#   1. 每套环境一个独立 CA(测试 = lab 自己的 CA,生产 = 独立根)"
echo "#   2. 证书文件与配置模板按环境参数化,不允许把 CA 路径写死在配置里"
echo "#   3. 测试环境的信任根绝不能出现在生产的 ssl_client_certificate / truststore 里"
echo "# 整改:测试配置改为引用测试 CA,删掉抄生产的坏配置:"
run sed -n '1,6p' "$D/test-nginx-test-ca.conf"
rm -f "$D/test-nginx-prod-ca.conf"

# ── 验证 ──
stage "验证"
echo "# 复检:配置里只剩测试 CA 引用,再无 prod 字样:"
run grep -rn "ssl_client_certificate\|prod" "$D" | sed "s|$PWD/||" || echo "(无 prod 引用)"
echo "# (本仓库全部 lab 证书由 lab CA 签发,生产证书走生产 PKI——两套信任互不相通)"

echo "# 结论:信任是传染的——测试环境接生产 CA 的那一刻,隔离就没了。"
