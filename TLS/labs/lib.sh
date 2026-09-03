#!/usr/bin/env bash
# =============================================================
# TLS labs 公共库:路径/端口常量 + 配置渲染/装载函数
# 用法:场景脚本第一行 source "$(dirname "$0")/../lib.sh"
# 兼容 macOS 自带 bash 3.2(不用关联数组)
# =============================================================
set -uo pipefail

LABS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$LABS_DIR/certs/out"
TPL="$LABS_DIR/nginx/nginx.conf.tpl"
FRAG_DIR="$LABS_DIR/nginx/fragments"
GEN_CONF="$LABS_DIR/nginx/nginx.conf.gen"
OUT_DIR="$LABS_DIR/out"
CNAME="tls-lab"
IMG="nginx:stable-alpine"

# host 端口(文档示例统一用这些)
HOST_TERM=1443    # termination 前端 443
HOST_MTLS=8443    # mTLS 前端
HOST_BACKEND=9443 # TLS 后端
HOST_PASS=4443    # passthrough
HOST_ECHO=18080   # 直连 8080 echo(备用)

# ---------- 配置参数(场景覆写这些变量后调 render/reload) ----------
# 证书 token:值为文件名(自动补容器内路径);片段 token:值为 fragments/ 下的名字
WWW_CERT="server-www.crt"
WWW_KEY="server-www.key"
BACKEND_CERT="server-api.crt"
BACKEND_KEY="server-api.key"
EXTRA_CERT="server-other.crt"
EXTRA_KEY="server-other.key"
TICKET_KEY="ticket.key"
FRAG_AUTHZ_MAP=""                  # authz-map / 空=不启用白名单
FRAG_EXTRA_443_SERVER=""           # extra-server-other / 空=只有一个域名
FRAG_CIPHERS=""                    # ciphers-12-aes-only / ciphers-12-13-aes-only
FRAG_FRONT_LOC="front-http-echo"   # front-http-echo / front-http-xfp-off / front-bridge-verify-off / front-bridge-verify-on
FRAG_AUTHZ_DENY=""                 # authz-deny-if
FRAG_PASS_DEFAULT="pass-default"   # pass-default / 空=map 无 default

# 把 #@FRAG:name@ 行展开为 fragments/<选中片段>.conf,再替换 @TOKEN@
# 注意:最终写入用 cat >(截断原 inode),不用 perl -i/mv 换名——容器绑定挂载对
# "换名覆盖"偶发拿到旧句柄(podman/gvproxy),截断式写入始终可见
render_conf() {
  mkdir -p "$(dirname "$GEN_CONF")"
  touch "$GEN_CONF"
  local tmp="$GEN_CONF.tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#@FRAG:*@)
        slot="${line#\#@FRAG:}"; slot="${slot%@}"
        sel="FRAG_$slot"; fname="${!sel-}"
        if [ -n "$fname" ] && [ -f "$FRAG_DIR/$fname.conf" ]; then
          cat "$FRAG_DIR/$fname.conf"
        fi
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$TPL" > "$tmp"

  local t val
  for t in WWW_CERT WWW_KEY BACKEND_CERT BACKEND_KEY EXTRA_CERT EXTRA_KEY TICKET_KEY; do
    val="${!t-}"
    [ -z "$val" ] && continue
    case "$t" in
      WWW_CERT|WWW_KEY|BACKEND_CERT|BACKEND_KEY|EXTRA_CERT|EXTRA_KEY|TICKET_KEY)
        val="/etc/nginx/certs/$val" ;;
    esac
    perl -pi -e "s|\@$t\@|$val|g" "$tmp"
  done
  cat "$tmp" > "$GEN_CONF"
  rm -f "$tmp"
}

# 重新装载配置:nginx -t 通过后 reload(默认静默,失败才打印)
reload_conf() {
  render_conf
  local out
  if out=$(docker exec "$CNAME" nginx -t -c /etc/nginx/lab/nginx.conf.gen 2>&1); then
    docker exec "$CNAME" nginx -s reload -c /etc/nginx/lab/nginx.conf.gen >/dev/null 2>&1
    sleep 0.3
    return 0
  fi
  echo "[nginx -t 失败] $out"
  return 1
}

# 容器起/停
start_lab() {
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  render_conf
  docker run -d --name "$CNAME" \
    -p 1443:443 -p 8443:8443 -p 9443:9443 -p 4443:4443 -p 18080:8080 \
    -v "$CERT_DIR:/etc/nginx/certs:ro" \
    -v "$LABS_DIR/nginx:/etc/nginx/lab:ro" \
    "$IMG" nginx -g 'daemon off;' -c /etc/nginx/lab/nginx.conf.gen >/dev/null
  sleep 0.5
  # bridging 用域名上游(api.example.com → 容器内 127.0.0.1:9443),保证 SNI 语义真实
  docker exec "$CNAME" sh -c "grep -q 'api.example.com' /etc/hosts || echo '127.0.0.1 api.example.com' >> /etc/hosts"
}

stop_lab() { docker rm -f "$CNAME" >/dev/null 2>&1; }

# 小工具:带分隔线的场景输出(run 合并 stderr,保证转录可复现)
section() { printf '\n───── %s ─────\n' "$*"; }
stage()  { printf '\n──────── %s ────────\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1; }
# 管道型命令按原样展示并执行(参数是完整命令行字符串)
pipe() { printf '\n$ %s\n' "$1"; eval "$1" 2>&1; }

# 场景参数复位(每个场景开头先复位,再覆写自己需要的)
reset_cfg() {
  WWW_CERT="server-www.crt";       WWW_KEY="server-www.key"
  BACKEND_CERT="server-api.crt";   BACKEND_KEY="server-api.key"
  EXTRA_CERT="server-other.crt";   EXTRA_KEY="server-other.key"
  TICKET_KEY="ticket.key"
  FRAG_AUTHZ_MAP="";               FRAG_EXTRA_443_SERVER=""
  FRAG_CIPHERS=""
  FRAG_FRONT_LOC="front-http-echo"; FRAG_AUTHZ_DENY=""
  FRAG_PASS_DEFAULT="pass-default"
}

# 容器未运行则先拉起
start_if_needed() {
  if ! docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null | grep -q '^true$'; then
    start_lab
  fi
}
