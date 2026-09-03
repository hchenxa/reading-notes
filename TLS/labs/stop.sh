#!/usr/bin/env bash
# 停止并删除 TLS labs 容器
set -uo pipefail
cd "$(dirname "$0")"
source ./lib.sh
stop_lab
echo "已停止 $CNAME"
