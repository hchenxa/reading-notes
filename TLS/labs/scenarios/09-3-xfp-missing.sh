#!/usr/bin/env bash
# ②09 坑三:Termination 忘了 X-Forwarded-Proto
# 运行:bash scenarios/09-3-xfp-missing.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
CA="certs/out/ca/lab-ca.crt"

section "坑三:Termination 忘了透传 X-Forwarded-Proto —— 后端以为用户走的是 http"
# ── 现象 ──
stage "现象"
echo "# termination 的 location 只写了 proxy_pass,没透传任何转发头:"
echo "#   location / { proxy_pass http://127.0.0.1:8080; }"
FRAG_FRONT_LOC=front-http-xfp-off reload_conf
echo "# 用户明明走 https,后端却收到空的 X-Forwarded-Proto(回显 xfp=[]):"
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/
echo "# 后果:后端据此生成 http 开头的绝对跳转/回调地址 → 登录态、防盗链连环错"

# ── 排查 ──
stage "排查"
echo "# 在后端打一行日志或起个 echo 接口看收到的头;或直接在代理层 curl -v 看请求头里有没有转发头:"
if curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" -v https://www.example.com:1443/ -o /dev/null 2>&1 | grep -q '^> X-Forwarded'; then
  echo "(请求头里有 X-Forwarded-* ?)"
else
  echo "(请求头里没有任何 X-Forwarded-Proto —— 后端更不可能有,问题定位在代理层)"
fi

# ── 修复 ──
stage "修复"
echo "# location 里补上两条 proxy_set_header:"
echo '#   proxy_set_header X-Forwarded-Proto $scheme;'
echo '#   proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;'
FRAG_FRONT_LOC=front-http-echo reload_conf

# ── 验证 ──
stage "验证"
run curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert "$CA" https://www.example.com:1443/

echo "# 结论:termination 是后端唯一的信息源,转发头必配;没配时后端眼里永远是 http。"
