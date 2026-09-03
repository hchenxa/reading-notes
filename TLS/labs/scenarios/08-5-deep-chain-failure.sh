#!/usr/bin/env bash
# ④08 排障 row5:深层 verify failed(链上一环的信任断了)
# 运行:bash scenarios/08-5-deep-chain-failure.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="certs/out"; CA="$C/ca/lab-ca.crt"

section "08-5 深层 certificate verify failed —— 链完整,但客户端信任的锚不对"
echo "# 场景:服务端把 叶子+中间CA 全发了(链完整);调用方却把"中间 CA"当信任锚"
echo "# (没装根)。中间 CA 由根签发,中间 CA 自己不是可信锚 → 链验证在深层断掉。"
# ── 现象 ──
stage "现象"
echo "# 服务器下发完整链(叶子+中间):"
WWW_CERT=server-chain-full.crt WWW_KEY=server-chain-leaf.key reload_conf
echo "# 客户端把中间 CA 当 --cacert:openssl 报 error 21(unable to verify the first certificate):"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -CAfile $C/ca/intermediate.crt 2>/dev/null | grep -iE 'verification|verify return' | head -2"
echo "# curl 报的是同一根因的"深层"文案(unable to get local issuer)——"
echo "# 这类报错看不出断在哪一环,得靠下面逐层 verify:"
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $C/ca/intermediate.crt https://www.example.com:1443/ 2>&1 | head -2"

# ── 排查:排障三连 ──
stage "排查:排障三连"
echo "# ① 线上链确实发全了(2 张)——不是服务器缺链:"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -showcerts 2>/dev/null | grep -c 'BEGIN CERTIFICATE'"
echo "# ② verify 逐层报错,error 2 at 1 depth(断在第二层=中间CA之上):"
run openssl verify -CAfile "$C/ca/intermediate.crt" -verbose "$C/server-chain-leaf.crt"
echo "# ③ 换根来验同一张叶子:链路其实健康 → 问题在客户端信任配置:"
run openssl verify -CAfile "$CA" -untrusted "$C/ca/intermediate.crt" "$C/server-chain-leaf.crt"

# ── 修复 ──
stage "修复"
echo "# 客户端信任锚换成真正的根(lab-ca.crt),而不是半截中间 CA:"
echo "#   服务器:照旧下发 叶子+中间(链完整)"
echo "#   客户端:--cacert lab-ca.crt / 系统信任库装根"
pipe "curl --noproxy '*' -sS --max-time 6 --resolve www.example.com:1443:127.0.0.1 --cacert $CA https://www.example.com:1443/"

# ── 验证 ──
stage "验证"
echo "# openssl s_client 用根做 -CAfile:Verification: OK(金标准):"
pipe "echo | openssl s_client -connect 127.0.0.1:1443 -servername www.example.com -CAfile $CA 2>/dev/null | grep -iE 'verification' | head -1"
echo "# verify 三件套全绿:"
run openssl verify -CAfile "$CA" -untrusted "$C/ca/intermediate.crt" "$C/server-chain-leaf.crt"
WWW_CERT=server-www.crt WWW_KEY=server-www.key reload_conf   # 恢复默认
