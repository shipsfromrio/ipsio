#!/bin/bash
# Builds the Mac App Store edition into dist/: universal (Apple silicon and
# Intel), macOS 13 or newer, sandboxed, compiled with -D STORE (no
# POST_RECORDING hook, no CALENDAR_COMMAND, no LaunchAgent; "Open at login"
# goes through macOS). Run on a Mac with the Command Line Tools:
#   bash build-store.sh                 # ad hoc: a local sandbox test
#   IPSIO_STORE_SIGN='Apple Distribution: NAME (TEAM)' IPSIO_TEAM=TEAM \
#   IPSIO_PROFILE=~/ipsio.provisionprofile \
#   IPSIO_INSTALLER_SIGN='3rd Party Mac Developer Installer: NAME (TEAM)' bash build-store.sh
# The second form also writes dist/Ipsio.pkg, the file Transporter uploads.
#
# Optional: IPSIO_STORE_BUNDLE_ID (io.github.shipsfromrio.ipsio.store),
# IPSIO_VERSION (1.0), IPSIO_BUILD (the commit count).
set -e
cd "$(dirname "$0")"
BID="${IPSIO_STORE_BUNDLE_ID:-io.github.shipsfromrio.ipsio.store}"
VERSION="${IPSIO_VERSION:-1.0}"
BUILD="${IPSIO_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN="${IPSIO_STORE_SIGN:--}"
OUT=dist; APP="$OUT/Ipsio.app"
SRC=(app/Schedule.swift app/MacCalendar.swift app/Setup.swift app/SetupWindow.swift app/Consent.swift app/Report.swift app/MeetingDetect.swift app/Search.swift app/SearchWindow.swift app/HotKey.swift app/Engine/*.swift app/Ipsio.swift)
for d in app/Store app/Transcribe; do [ -d "$d" ] && SRC+=("$d"/*.swift); done

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "== building (arm64 + x86_64) =="
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -D STORE -target "$arch-apple-macos13.0" "${SRC[@]}" -framework AppKit -o "$T/Ipsio-$arch" 2>&1 | grep -v warning || true
  [ -x "$T/Ipsio-$arch" ] || { echo "build failed for $arch"; exit 1; }
done
lipo -create "$T/Ipsio-arm64" "$T/Ipsio-x86_64" -output "$APP/Contents/MacOS/Ipsio"

USAGE_CAL="Ipsio reads your meetings from the Calendar app to record them at the right time. Nothing leaves the Mac. / O Ipsio lê as reuniões do app Calendário para gravá-las na hora certa. Nada sai do Mac."
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Ipsio</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>Ipsio</string>
  <key>CFBundleDisplayName</key><string>Ipsio</string>
  <key>CFBundleIconFile</key><string>Ipsio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>$USAGE_CAL</string>
  <key>NSCalendarsUsageDescription</key><string>$USAGE_CAL</string>
  <key>NSMicrophoneUsageDescription</key><string>In meeting mode, Ipsio records your voice in its own track. It stays on this Mac. / No modo reunião, o Ipsio grava a sua voz numa faixa própria. Ela fica neste Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Ipsio transcribes your recordings on this Mac, never on a server. / O Ipsio transcreve as suas gravações neste Mac, nunca num servidor.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The App Store checks which SDK and Xcode built the app (the DT keys Xcode
# writes). A store upload needs Xcode installed; an ad hoc build does not.
PB=/usr/libexec/PlistBuddy; P="$APP/Contents/Info.plist"
SDKV=$(xcrun --sdk macosx --show-sdk-version); SDKB=$(xcrun --sdk macosx --show-sdk-build-version)
for kv in "DTSDKName macosx$SDKV" "DTSDKBuild $SDKB" "DTPlatformName macosx" "DTPlatformVersion $SDKV" \
          "DTPlatformBuild $SDKB" "DTCompiler com.apple.compilers.llvm.clang.1_0" "BuildMachineOSBuild $(sw_vers -buildVersion)"; do
  $PB -c "Add :${kv%% *} string ${kv#* }" "$P"
done
if XV=$(xcodebuild -version 2>/dev/null); then
  # "Xcode 16.4" -> 1640, "Xcode 26.0.1" -> 2601
  $PB -c "Add :DTXcode string $(echo "$XV" | awk 'NR==1{split($2,v,"."); printf "%d%d%d", v[1], v[2], v[3]}')" "$P"
  $PB -c "Add :DTXcodeBuild string $(echo "$XV" | awk 'NR==2{print $3}')" "$P"
elif [ -n "${IPSIO_TEAM:-}" ]; then
  echo "a store upload needs Xcode (xcode-select -s /Applications/Xcode.app); the Command Line Tools alone are refused"; exit 1
fi

if [ -f icon.png ]; then
  I="$T/Ipsio.iconset"; mkdir -p "$I"
  for n in 16 32 128 256 512; do
    sips -z $n $n icon.png --out "$I/icon_${n}x${n}.png" >/dev/null
    sips -z $((n*2)) $((n*2)) icon.png --out "$I/icon_${n}x${n}@2x.png" >/dev/null
  done
  iconutil -c icns "$I" -o "$APP/Contents/Resources/Ipsio.icns"
else
  echo "WARNING: no icon.png; the store refuses an app without an icon"
fi

echo "== signing =="
ENT="$T/Ipsio.entitlements"; cp store/Ipsio.entitlements "$ENT"
if [ -n "${IPSIO_TEAM:-}" ]; then
  # Distribution needs the app and team identifiers in the signature.
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $IPSIO_TEAM.$BID" "$ENT"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $IPSIO_TEAM" "$ENT"
fi
[ -n "${IPSIO_PROFILE:-}" ] && cp "$IPSIO_PROFILE" "$APP/Contents/embedded.provisionprofile"
codesign --force -s "$SIGN" --entitlements "$ENT" "$APP"
codesign --verify --strict "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox || { echo "the sandbox entitlement is missing"; exit 1; }
lipo -archs "$APP/Contents/MacOS/Ipsio"

if [ -n "${IPSIO_INSTALLER_SIGN:-}" ]; then
  productbuild --component "$APP" /Applications --sign "$IPSIO_INSTALLER_SIGN" "$OUT/Ipsio.pkg"
  echo "upload: $OUT/Ipsio.pkg (Transporter)"
fi
[ "$SIGN" = "-" ] && WHO="ad hoc" || WHO="$SIGN"
echo "built: $APP ($BID $VERSION ($BUILD), signed $WHO)"
