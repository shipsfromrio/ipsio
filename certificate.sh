#!/bin/bash
# Creates the self-signed "Ipsio Dev" certificate (or $IPSIO_CERT) in the
# SYSTEM keychain and uses it to sign the app. Once per Mac. Run: bash certificate.sh
#
# Why: the Screen Recording and Microphone permissions are bound to the app's
# designated requirement; signed ad hoc it changes on every build and the
# permission vanishes. With this certificate the requirement becomes
# `identifier "<bundle id>" and certificate leaf = H"..."`, stable. The
# certificate does NOT need to be marked as trusted for that: TCC checks the
# requirement, not the chain. That is why the trust step (security
# add-trusted-cert) is left out: it needs on-screen interaction and changes
# nothing for the app. Without it `security find-identity -v` lists zero valid
# identities, and codesign signs anyway.
#
# The private key is born here, only on this Mac, and never leaves it. Asks for
# sudo (imports into the system keychain, so codesign finds the key without
# unlocking the login keychain over ssh).
set -e
IDENT="${IPSIO_CERT:-Ipsio Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENT\""; then
  echo "certificate '$IDENT' already exists"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=$(openssl rand -hex 16)   # only protects the temporary .p12, which dies at the end
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -nodes \
  -subj "/CN=$IDENT" -addext "keyUsage=digitalSignature" -addext "extendedKeyUsage=codeSigning" 2>/dev/null
/usr/bin/openssl pkcs12 -export -out "$T/id.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout "pass:$PASS" -name "$IDENT"
sudo security import "$T/id.p12" -k /Library/Keychains/System.keychain -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security
security find-identity -p codesigning | grep "$IDENT" && echo "created. Now: bash install-app.sh (re-signs the app)."
