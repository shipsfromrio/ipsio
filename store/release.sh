#!/bin/bash
# release.sh: the signed store build, checked, then sent to App Store Connect
# (TestFlight first, then the review is started in the browser). Run on the
# Mac with Xcode installed:
#
#   IPSIO_TEAM=ABCDE12345 \
#   IPSIO_STORE_SIGN='Apple Distribution: NAME (ABCDE12345)' \
#   IPSIO_INSTALLER_SIGN='3rd Party Mac Developer Installer: NAME (ABCDE12345)' \
#   IPSIO_PROFILE=~/Downloads/Ipsio_Mac_App_Store.provisionprofile \
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
#   bash store/release.sh            # validate only
#   ... bash store/release.sh --upload
#
# ASC_KEY_ID / ASC_ISSUER: an App Store Connect API key (Users and Access >
# Integrations), its AuthKey_<ID>.p8 in ~/.appstoreconnect/private_keys/.
# Nothing secret is printed or written to the repository.
set -e
cd "$(dirname "$0")/.."
for v in IPSIO_TEAM IPSIO_STORE_SIGN IPSIO_INSTALLER_SIGN IPSIO_PROFILE ASC_KEY_ID ASC_ISSUER; do
  [ -n "${!v}" ] || { echo "missing $v (see the top of store/release.sh)"; exit 2; }
done
[ -f "$IPSIO_PROFILE" ] || { echo "no profile at $IPSIO_PROFILE"; exit 2; }
[ -f ~/.appstoreconnect/private_keys/AuthKey_"$ASC_KEY_ID".p8 ] || { echo "no API key file AuthKey_$ASC_KEY_ID.p8 in ~/.appstoreconnect/private_keys/"; exit 2; }
xcodebuild -version >/dev/null 2>&1 || { echo "Xcode is needed: install it and run sudo xcode-select -s /Applications/Xcode.app"; exit 2; }
# A beta SDK is refused by the store.
SDKV=$(xcrun --sdk macosx --show-sdk-version)
xcodebuild -version | head -1 | grep -qi beta && { echo "Xcode is a beta: the store refuses it"; exit 2; }

# Every upload needs a build number never used before: the commit count, plus
# a time stamp when the same commit is sent twice.
export IPSIO_BUILD="${IPSIO_BUILD:-$(git rev-list --count HEAD).$(date +%H%M)}"
bash build-store.sh

PKG=dist/Ipsio.pkg
[ -f "$PKG" ] || { echo "no $PKG"; exit 1; }
pkgutil --check-signature "$PKG" | grep -q "Status: signed" || { echo "the package is not signed"; exit 1; }
codesign -d --entitlements - dist/Ipsio.app 2>/dev/null | grep -q "$IPSIO_TEAM" || { echo "the team identifier is missing from the signature"; exit 1; }
echo "SDK macosx$SDKV, build $IPSIO_BUILD"

AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER")
echo "== validating with App Store Connect =="
xcrun altool --validate-app -f "$PKG" -t macos "${AUTH[@]}"
if [ "${1:-}" = "--upload" ]; then
  echo "== uploading =="
  xcrun altool --upload-app -f "$PKG" -t macos "${AUTH[@]}"
  echo "uploaded: in a few minutes the build shows in App Store Connect > TestFlight"
else
  echo "valid. To send it: the same command with --upload"
fi
