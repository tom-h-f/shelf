#!/bin/zsh
# Create a self-signed code signing identity "Shelf Local Code Signing" in the login keychain.
# A stable identity keeps macOS privacy grants (Downloads, Automation) across reinstalls; ad-hoc signatures change every build.
set -euo pipefail
name="Shelf Local Code Signing"
if security find-identity -p codesigning | grep -q "$name"; then
  echo "identity exists: $name"
  exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
  -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
pass=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$name" -passout "pass:$pass" -out "$dir/id.p12"
security import "$dir/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign
echo "imported: $name"
security find-identity -p codesigning | grep "$name"
