#!/usr/bin/env bash
# 启动/重置 TLS labs 环境(nginx 容器)
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
start_lab
echo "容器 $CNAME 已启动,默认配置已装载。"
echo "  用法: bash scenarios/run-all.sh  或单个场景脚本"
echo "  停止: bash stop.sh"
