#!/usr/bin/env bash
#
# 创建一个本地代码签名用的自签名证书。
#
# 为什么需要它
# ------------
# build.sh 默认用 ad-hoc 签名（codesign --sign -），它的 designated requirement 是：
#
#     designated => cdhash H"91cd0f4b..."
#
# 直接绑定二进制哈希。每次编译哈希都变，macOS 会认为这是一个**全新的 App**，
# 之前授予的「辅助功能」权限随之失效，得删掉重新添加。
#
# 换成固定证书之后，DR 变成：
#
#     designated => identifier "com.local.paste" and certificate leaf = H"4e23..."
#
# 只跟证书绑定，跟二进制内容无关。实测改动源码重新编译后 CDHash 变了、DR 一字不差，
# 这就是授权能一直有效的原因。
#
# 用法
# ----
#     ./setup-signing-cert.sh          # 创建（可重复执行，已就绪就跳过）
#     ./setup-signing-cert.sh --remove # 删除证书和信任设置
#
# 之后 ./build.sh 会自动发现并使用这个证书，不需要改脚本。
#
set -euo pipefail

CERT_NAME="${PASTE_CERT_NAME:-Paste Self Signed}"
KEYCHAIN="${PASTE_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
DAYS="${PASTE_CERT_DAYS:-3650}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 只列**有效**身份。不带 -v 的话 security 会同时打印「Matching identities」和
# 「Valid identities only」两段，同一个身份被匹配到两次。
find_identity() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -F "\"$CERT_NAME\"" || true
}

# 导出证书（不管有没有被信任）
export_cert() {
  security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" 2>/dev/null
}

# ---------------------------------------------------------------- 删除

if [ "${1:-}" = "--remove" ]; then
  if ! export_cert > "$WORK/cert.pem" || [ ! -s "$WORK/cert.pem" ]; then
    echo "证书「${CERT_NAME}」不存在，无需删除"
    exit 0
  fi

  # 先撤信任，再删身份
  security remove-trusted-cert "$WORK/cert.pem" < /dev/null 2>/dev/null \
    && echo "✓ 已移除信任设置" \
    || echo "（没有找到信任设置，跳过）"

  security delete-identity -c "$CERT_NAME" "$KEYCHAIN" 2>/dev/null || true
  echo "✓ 已从钥匙串删除证书「${CERT_NAME}」"
  echo
  echo "之后 ./build.sh 会退回 ad-hoc 签名，重新编译就需要重新授权了。"
  exit 0
fi

# ---------------------------------------------------------------- 已经就绪

if [ -n "$(find_identity)" ]; then
  echo "✓ 证书「${CERT_NAME}」已就绪，跳过创建"
  find_identity | sed 's/^/    /'
  echo
  echo "直接 ./build.sh 即可，它会自动使用这个证书。"
  exit 0
fi

if export_cert > "$WORK/cert.pem" && [ -s "$WORK/cert.pem" ]; then
  # 证书在钥匙串里，但没有被信任（比如上次跑到一半中断了）。
  # 这种情况补一下信任即可，不用重新导入——否则会多出一张同名证书。
  echo "==> 证书已存在但未受信任，补设信任"
else
  echo "==> 生成私钥与自签名证书（有效期 $DAYS 天）"
  cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $CERT_NAME

[ ext ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days "$DAYS" -config "$WORK/openssl.cnf" >/dev/null 2>&1

  # 两个坑，都实测踩过：
  #   1. OpenSSL 3.x 默认的 PKCS#12 加密（AES-256 + SHA-256）macOS 的 security 认不了，
  #      会报 "MAC verification failed during PKCS12 import"。必须退回 SHA1/3DES
  #      （等价于 openssl 的 -legacy）。
  #   2. 密码不能为空，空密码同样报 MAC 验证失败。
  P12_PASS="paste-setup-$$"
  openssl pkcs12 -export \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/cert.p12" \
    -passout "pass:$P12_PASS" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

  echo "==> 导入钥匙串"
  # 只授权 /usr/bin/codesign 使用私钥（而不是 -A 对所有程序放开）
  if ! security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" \
        -T /usr/bin/codesign < /dev/null; then
    echo "✗ 导入失败"
    exit 1
  fi

  echo "==> 设置信任"
fi

# 不加 -d：写进的是「当前用户」的信任设置，不需要管理员密码。
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" < /dev/null

echo
echo "==> 结果"
if [ -z "$(find_identity)" ]; then
  echo "✗ 证书没有出现在代码签名身份列表里"
  exit 1
fi
find_identity | sed 's/^/    /'

echo
echo "现在执行 ./build.sh，它会自动发现并使用这个证书。"
echo
echo "要删掉： ./setup-signing-cert.sh --remove"
