#!/usr/bin/env bash
# =============================================================
# TLS labs 证书物料生成脚本
# 产物目录:certs/out/   可重复执行(每次先清空)
# 要求:OpenSSL 3.x(本机 3.6.2 验证过 -addext / ca -enddate / -copy_extensions)
# =============================================================
set -euo pipefail

cd "$(dirname "$0")"
OUT="$(pwd)/out"
rm -rf "$OUT"
mkdir -p "$OUT/ca"

# ---------- 工具函数 ----------
gen_key() { openssl genrsa -out "$1" 2048 2>/dev/null; }
new_csr() { openssl req -new -key "$1" -subj "$2" -out "$3"; }

# 由 lab CA 用 x509 -req 签叶子证书(文章里 ③04 章的同款姿势)
# $1=csr $2=证书输出 $3=extfile(可选,缺省不带任何扩展)
sign_leaf() {
  local csr="$1" crt="$2" ext="${3:-}"
  if [ -n "$ext" ]; then
    openssl x509 -req -in "$csr" -CA "$OUT/ca/lab-ca.crt" -CAkey "$OUT/ca/lab-ca.key" \
      -CAcreateserial -days 365 -out "$crt" -extfile "$ext"
  else
    openssl x509 -req -in "$csr" -CA "$OUT/ca/lab-ca.crt" -CAkey "$OUT/ca/lab-ca.key" \
      -CAcreateserial -days 365 -out "$crt"
  fi
}

# 通用 server 叶子扩展(不含 SAN 行,SAN 由调用方拼进文件)
cat > "$OUT/server.ext.tpl" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
cat > "$OUT/client.ext.tpl" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF

# ---------- 0. CA ----------
echo "==> 生成 lab CA"
gen_key  "$OUT/ca/lab-ca.key"
openssl req -x509 -new -key "$OUT/ca/lab-ca.key" -days 3650 \
  -subj "/CN=Lab Internal Root CA" -out "$OUT/ca/lab-ca.crt"

# ---------- 1. 中间 CA(lab CA 签) ----------
echo "==> 生成中间 CA"
gen_key "$OUT/ca/intermediate.key"
new_csr "$OUT/ca/intermediate.key" "/CN=Lab Intermediate CA" "$OUT/ca/intermediate.csr"
cat > "$OUT/intermediate.ext" <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
EOF
openssl x509 -req -in "$OUT/ca/intermediate.csr" \
  -CA "$OUT/ca/lab-ca.crt" -CAkey "$OUT/ca/lab-ca.key" \
  -CAcreateserial -days 1825 -out "$OUT/ca/intermediate.crt" \
  -extfile "$OUT/intermediate.ext"

# ---------- 2. server 证书 ----------
echo "==> 生成 server 证书"
# 2a. 好证书(带 SAN)——nginx 默认加载
gen_key "$OUT/server-www.key"
new_csr "$OUT/server-www.key" "/CN=www.example.com" "$OUT/server-www.csr"
printf "subjectAltName=DNS:www.example.com,DNS:example.com,DNS:localhost,IP:127.0.0.1\n" \
  | cat - "$OUT/server.ext.tpl" > "$OUT/server-www.ext"
sign_leaf "$OUT/server-www.csr" "$OUT/server-www.crt" "$OUT/server-www.ext"

# 2a2. 第二张 www 证书(同域名同 SAN,不同有效期——"换了证书没 reload"演示)
gen_key "$OUT/server-www2.key"
openssl req -new -key "$OUT/server-www2.key" \
  -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:example.com,DNS:localhost,IP:127.0.0.1" \
  -out "$OUT/server-www2.csr"
openssl x509 -req -in "$OUT/server-www2.csr" -CA "$OUT/ca/lab-ca.crt" -CAkey "$OUT/ca/lab-ca.key" \
  -CAcreateserial -days 30 -out "$OUT/server-www2.crt" -extfile "$OUT/server-www.ext"

# 2b. 过期证书(有效期整体在过去,openssl ca -startdate/-enddate 造假时间)
gen_key "$OUT/server-expired.key"
new_csr "$OUT/server-expired.key" "/CN=www.example.com" "$OUT/server-expired.csr"
openssl req -new -key "$OUT/server-expired.key" \
  -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:localhost,IP:127.0.0.1" \
  -out "$OUT/server-expired.csr"
cp "$OUT/server.ext.tpl" "$OUT/ca.cnf"   # 占位,下面 ca.cnf 会重写
cat > "$OUT/ca.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir            = $OUT/ca
database       = \$dir/index.txt
new_certs_dir  = \$dir
serial         = \$dir/serial
certificate    = \$dir/lab-ca.crt
private_key    = \$dir/lab-ca.key
default_md     = sha256
policy         = policy_any
copy_extensions = copy
unique_subject = no
[ policy_any ]
commonName      = supplied
EOF
touch "$OUT/ca/index.txt"
echo 1000 > "$OUT/ca/serial"
# -startdate/-enddate 都用过去时间 → 证书整体过期
openssl ca -batch -notext -config "$OUT/ca.cnf" \
  -startdate 20240101000000Z -enddate 20240901000000Z \
  -in "$OUT/server-expired.csr" -out "$OUT/server-expired.crt" 2>/dev/null
rm -f "$OUT/ca.cnf"

# 2c. 无 SAN 证书(只有 CN,且 CN=www.example.com 与域名一致)——现代客户端只认 SAN
gen_key "$OUT/server-nosan.key"
new_csr "$OUT/server-nosan.key" "/CN=www.example.com" "$OUT/server-nosan.csr"
sign_leaf "$OUT/server-nosan.csr" "$OUT/server-nosan.crt"   # 故意不给 extfile

# 2d. 自签证书(不是 lab CA 签的)
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -keyout "$OUT/server-selfsigned.key" \
  -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:localhost,IP:127.0.0.1" \
  -out "$OUT/server-selfsigned.crt" 2>/dev/null

# 2e. 中间 CA 签的 server(④ 链缺失演示:full=叶子+中间CA,leaf=只发叶子)
gen_key "$OUT/server-chain-leaf.key"
new_csr "$OUT/server-chain-leaf.key" "/CN=www.example.com" "$OUT/server-chain-leaf.csr"
openssl req -new -key "$OUT/server-chain-leaf.key" \
  -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:localhost,IP:127.0.0.1" \
  -out "$OUT/server-chain-leaf.csr"
openssl x509 -req -in "$OUT/server-chain-leaf.csr" \
  -CA "$OUT/ca/intermediate.crt" -CAkey "$OUT/ca/intermediate.key" \
  -CAcreateserial -days 365 -out "$OUT/server-chain-leaf.crt" \
  -copy_extensions copy -extfile "$OUT/server.ext.tpl"
cat "$OUT/server-chain-leaf.crt" "$OUT/ca/intermediate.crt" > "$OUT/server-chain-full.crt"

# 2f. 后端证书(api.example.com,bridging/passthrough 目标 9443 用)
gen_key "$OUT/server-api.key"
new_csr "$OUT/server-api.key" "/CN=api.example.com" "$OUT/server-api.csr"
printf "subjectAltName=DNS:api.example.com,DNS:localhost,IP:127.0.0.1\n" \
  | cat - "$OUT/server.ext.tpl" > "$OUT/server-api.ext"
sign_leaf "$OUT/server-api.csr" "$OUT/server-api.crt" "$OUT/server-api.ext"

# 2g. 另一个域名的证书(一个 IP 多证书串台演示)
gen_key "$OUT/server-other.key"
new_csr "$OUT/server-other.key" "/CN=other.example.com" "$OUT/server-other.csr"
printf "subjectAltName=DNS:other.example.com,DNS:localhost,IP:127.0.0.1\n" \
  | cat - "$OUT/server.ext.tpl" > "$OUT/server-other.ext"
sign_leaf "$OUT/server-other.csr" "$OUT/server-other.crt" "$OUT/server-other.ext"

# ---------- 3. client 证书(lab CA 签) ----------
echo "==> 生成 client 证书"
# 3a. 好客户端×2(身份写在 CN)
for c in client-01 client-02; do
  gen_key "$OUT/$c.key"
  new_csr "$OUT/$c.key" "/CN=$c/OU=payment-service" "$OUT/$c.csr"
  cp "$OUT/client.ext.tpl" "$OUT/$c.ext"
  sign_leaf "$OUT/$c.csr" "$OUT/$c.crt" "$OUT/$c.ext"
done
mv "$OUT/client-01.crt" "$OUT/client-alice.crt"; mv "$OUT/client-01.key" "$OUT/client-alice.key"
mv "$OUT/client-02.crt" "$OUT/client-bob.crt";   mv "$OUT/client-02.key" "$OUT/client-bob.key"

# 3b. 过期客户端证书(整体过期)
gen_key "$OUT/client-expired.key"
openssl req -new -key "$OUT/client-expired.key" \
  -subj "/CN=client-expired/OU=payment-service" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "extendedKeyUsage=clientAuth" \
  -out "$OUT/client-expired.csr"
cat > "$OUT/ca.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir            = $OUT/ca
database       = \$dir/index.txt
new_certs_dir  = \$dir
serial         = \$dir/serial
certificate    = \$dir/lab-ca.crt
private_key    = \$dir/lab-ca.key
default_md     = sha256
policy         = policy_any
copy_extensions = copy
unique_subject = no
[ policy_any ]
commonName      = supplied
EOF
openssl ca -batch -notext -config "$OUT/ca.cnf" \
  -startdate 20240101000000Z -enddate 20240901000000Z \
  -in "$OUT/client-expired.csr" -out "$OUT/client-expired.crt" 2>/dev/null
rm -f "$OUT/ca.cnf"

# 3c. 会被吊销的客户端证书(吊销见下)
gen_key "$OUT/client-revoked.key"
new_csr "$OUT/client-revoked.key" "/CN=client-revoked/OU=payment-service" "$OUT/client-revoked.csr"
openssl req -new -key "$OUT/client-revoked.key" \
  -subj "/CN=client-revoked/OU=payment-service" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "extendedKeyUsage=clientAuth" \
  -out "$OUT/client-revoked.csr"

# ---------- 4. 吊销 + CRL ----------
echo "==> 生成吊销记录与 CRL"
cat > "$OUT/ca.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir            = $OUT/ca
database       = \$dir/index.txt
new_certs_dir  = \$dir
serial         = \$dir/serial
certificate    = \$dir/lab-ca.crt
private_key    = \$dir/lab-ca.key
default_md     = sha256
policy         = policy_any
copy_extensions = copy
unique_subject = no
default_crl_days = 365
[ policy_any ]
commonName      = supplied
[ crl_ext ]
authorityKeyIdentifier=keyid:always
EOF
# 用与上面 client 相同的 CSR 签一张可吊销证书,然后立刻吊销
openssl ca -batch -notext -config "$OUT/ca.cnf" -days 365 \
  -in "$OUT/client-revoked.csr" -out "$OUT/client-revoked.crt" 2>/dev/null
openssl ca -batch -config "$OUT/ca.cnf" -revoke "$OUT/client-revoked.crt" 2>/dev/null
openssl ca -batch -config "$OUT/ca.cnf" -gencrl -out "$OUT/ca/lab-ca.crl" 2>/dev/null
rm -f "$OUT/ca.cnf"

# ---------- 5. nginx 会话票据密钥 ----------
echo "==> 生成 session ticket key"
openssl rand 80 > "$OUT/ticket.key"

# ---------- 汇总 ----------
echo "==> 完成。产物清单:"
find "$OUT" -type f \( -name '*.crt' -o -name '*.key' -o -name '*.crl' -o -name 'ticket.key' \) | sed "s|$OUT/||" | sort
