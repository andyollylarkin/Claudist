#!/bin/bash
# Creates a local self-signed code-signing identity in the login keychain.
#
# Signing Claudist with a stable identity (instead of ad-hoc) keeps its code identity the same
# across rebuilds, so "Always Allow" on Keychain items (secrets, the container token) survives updates.
# The key is generated here and stays in the login keychain; temporary files are deleted.
set -euo pipefail

NAME=${1:-Claudist Local Signing}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identity \"$NAME\" already exists"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

# LibreSSL's PKCS#12 defaults are the ones `security import` understands.
OPENSSL=/usr/bin/openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$PASS"

# -T: codesign may use the key without asking each time.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security
echo "Created code-signing identity \"$NAME\" in the login keychain"
