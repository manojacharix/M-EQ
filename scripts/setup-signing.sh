#!/bin/zsh
# One-time: creates a self-signed "BassEQ Local Signing" code-signing identity in its own keychain.
# A stable signature means macOS keeps the System Audio Recording permission across rebuilds
# (ad-hoc signatures change every build, so macOS would ask again each time).
set -euo pipefail
NAME="BassEQ Local Signing"
CONF="$HOME/.config/basseq"
KC="$HOME/Library/Keychains/basseq-signing.keychain-db"
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  echo "Signing identity already exists"; exit 0
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cat > "$W/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$W/cert.cnf" \
  -keyout "$W/key.pem" -out "$W/cert.pem" 2>/dev/null
P12PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$W/key.pem" -in "$W/cert.pem" -out "$W/id.p12" \
  -passout "pass:$P12PASS" -name "$NAME"
mkdir -p "$CONF"; chmod 700 "$CONF"
KCPASS=$(openssl rand -hex 24)
printf '%s' "$KCPASS" > "$CONF/keychain-password"; chmod 600 "$CONF/keychain-password"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$W/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
# codesign only looks in keychains on the user search list.
EXISTING=(${(f)"$(security list-keychains -d user | tr -d '" ')"})
security list-keychains -d user -s "${EXISTING[@]}" "$KC"
echo "Created signing identity \"$NAME\""
