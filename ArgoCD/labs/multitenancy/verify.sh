#!/usr/bin/env bash
#
# 多租户 RBAC 回归测试：用本地账号跑 account can-i 矩阵。
#
# 前置条件：
#   - Argo CD 可通过 CLI 访问（默认 localhost:8080，通常用 port-forward）
#   - tenant-a-viewer / tenant-b-viewer / tenant-a-developer 已按 README 创建
#
# 用法：
#   export TENANT_A_VIEWER_PASSWORD='...'
#   export TENANT_B_VIEWER_PASSWORD='...'
#   export TENANT_A_DEVELOPER_PASSWORD='...'
#   ./verify.sh
#
# 可选：
#   export ARGOCD_SERVER='localhost:8080'
#   export ARGOCD_INSECURE='true'   # 默认 true；正式证书可设 false

set -euo pipefail

SERVER="${ARGOCD_SERVER:-localhost:8080}"
INSECURE="${ARGOCD_INSECURE:-true}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

: "${TENANT_A_VIEWER_PASSWORD:?set TENANT_A_VIEWER_PASSWORD}"
: "${TENANT_B_VIEWER_PASSWORD:?set TENANT_B_VIEWER_PASSWORD}"
: "${TENANT_A_DEVELOPER_PASSWORD:?set TENANT_A_DEVELOPER_PASSWORD}"

if ! command -v argocd >/dev/null 2>&1; then
  echo "argocd CLI not found in PATH" >&2
  exit 1
fi

login_user() {
  local user="$1"
  local password="$2"
  local config="$3"
  if ! argocd --config "$config" login "$SERVER" \
      --username "$user" --password "$password" \
      --insecure="$INSECURE" >/dev/null 2>&1; then
    echo "FAIL login: $user" >&2
    exit 1
  fi
}

run_case() {
  local user="$1"
  local config="$2"
  local action="$3"
  local resource="$4"
  local subresource="$5"
  local expected="$6"
  local got

  got="$(argocd --config "$config" account can-i "$action" "$resource" "$subresource" 2>&1 | tail -1 | tr -d '\r')"
  if [[ "$got" == "$expected" ]]; then
    printf 'PASS  %-20s %-8s %-12s %-30s => %s\n' \
      "$user" "$action" "$resource" "$subresource" "$got"
  else
    printf 'FAIL  %-20s %-8s %-12s %-30s expected=%s got=%s\n' \
      "$user" "$action" "$resource" "$subresource" "$expected" "$got"
    return 1
  fi
}

login_user tenant-a-viewer "$TENANT_A_VIEWER_PASSWORD" "$TMP_DIR/a-viewer.yaml"
login_user tenant-b-viewer "$TENANT_B_VIEWER_PASSWORD" "$TMP_DIR/b-viewer.yaml"
login_user tenant-a-developer "$TENANT_A_DEVELOPER_PASSWORD" "$TMP_DIR/a-dev.yaml"

failures=0
run_case tenant-a-viewer "$TMP_DIR/a-viewer.yaml" get  applications "team-a/guestbook-dev" yes || failures=$((failures + 1))
run_case tenant-a-viewer "$TMP_DIR/a-viewer.yaml" sync applications "team-a/guestbook-dev" no  || failures=$((failures + 1))
run_case tenant-a-viewer "$TMP_DIR/a-viewer.yaml" get  applications "team-b/guestbook-team-b-dev" no || failures=$((failures + 1))

run_case tenant-b-viewer "$TMP_DIR/b-viewer.yaml" get  applications "team-b/guestbook-team-b-dev" yes || failures=$((failures + 1))
run_case tenant-b-viewer "$TMP_DIR/b-viewer.yaml" get  applications "team-a/guestbook-dev" no || failures=$((failures + 1))

run_case tenant-a-developer "$TMP_DIR/a-dev.yaml" get  applications "team-a/guestbook-dev" yes || failures=$((failures + 1))
run_case tenant-a-developer "$TMP_DIR/a-dev.yaml" sync applications "team-a/guestbook-dev" yes || failures=$((failures + 1))
run_case tenant-a-developer "$TMP_DIR/a-dev.yaml" sync applications "team-b/guestbook-team-b-dev" no || failures=$((failures + 1))

if (( failures > 0 )); then
  echo "FAILED: $failures case(s)" >&2
  exit 1
fi

echo "All RBAC checks passed."
