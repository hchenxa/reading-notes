#!/usr/bin/env bash
# ③07 坑四:把客户端私钥塞进代码仓库
# 运行:bash scenarios/07-4-key-in-git.sh
set -uo pipefail
cd "$(dirname "$0")/.." && source ./lib.sh
reset_cfg && start_if_needed
C="$LABS_DIR/certs/out"
D="$LABS_DIR/out/_git-leak-demo"

section "坑四:客户端私钥进了代码仓库 —— 私钥=身份,进 git 等于把门禁贴墙上"
echo "# 先构造一个事故现场:有人在项目里提交了密钥文件"
# ── 现象 ──
stage "现象"
rm -rf "$D"; mkdir -p "$D/payment-service/keys"
cp "$C/client-alice.key" "$D/payment-service/keys/payment-service.pem"
printf '# 误提交示例(模拟真实事故)\n' > "$D/payment-service/keys/README.txt"
(
  cd "$D" || exit 1
  git init -q
  git config user.email lab@example.com
  git config user.name lab
  git add .
  git commit -qm "feat: add payment service mTLS client"
)
echo "# 事故仓库里躺着客户端私钥(ls-files 能看到):"
run bash -c "cd '$D' && git ls-files | sed 's|^|  |'"
run grep -rl "BEGIN.*PRIVATE KEY" "$D"

# ── 排查 ──
stage "排查"
echo "# 三条检出命令(全仓扫描 / git 内容检索 / git 历史提交):"
run grep -rn "BEGIN.*PRIVATE KEY" "$D" --include="*.pem"
run bash -c "cd '$D' && git log --all --oneline --name-only | grep -B1 'payment-service.pem'"
echo "#   ↑ git 历史里能看到密钥文件进过仓库"
run find "$D" \( -path "$D/.git" \) -prune -o \( -name "*.key" -o -name "*.pem" \) -print

# ── 修复 ──
stage "修复"
echo "# 第一步:立刻停止使用该私钥并重新签发(泄露过的私钥=作废,别指望能收回)"
echo "# 第二步:从工作区+索引移除,并加 .gitignore(只解决未来,历史还在):"
rm -f "$D/payment-service/keys/payment-service.pem"
printf 'keys/*.pem\nkeys/*.key\n' >> "$D/.gitignore"
run bash -c "cd '$D' && git add -A && git commit -qm 'chore: remove leaked key, ignore key files'"
echo "# 第三步:重写历史把密钥彻底抹掉,交给专用工具——git filter-repo(推荐):"
echo "#   git filter-repo --path keys/payment-service.pem --invert-paths"
echo "#   (本环境未安装 filter-repo,这里改用 git log -S 演示:为什么必须做第三步)"

# ── 验证 ──
stage "验证"
echo "# 工作区已干净:"
run bash -c "cd '$D' && grep -rn 'BEGIN.*PRIVATE KEY' --include='*.pem' --include='*.key' . || echo '(全仓无密钥内容)'"
echo "# 但 git log -S 还能捞到密钥内容——删除提交里躺着完整私钥(历史没抹,等于没删):"
run bash -c "cd '$D' && git log --all -p -S 'BEGIN PRIVATE KEY' --oneline | head -6"
echo "# 恢复现场(清掉演示仓库):"
rm -rf "$D"

echo "# 结论:私钥=身份;进过 git 的私钥一律当泄露处理——换新 + filter-repo 重写历史 + 防再犯(KMS)。"
