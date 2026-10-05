#!/bin/bash
# Builds the menu-bar app and ipsio-calendar, puts the icon and the recipe
# (ipsio.sh) inside the .app, signs it, registers the LaunchAgent (opens at
# login and comes back by itself when closed) and starts it. Run on the Mac,
# in the repository folder: bash install-app.sh   (install.sh calls it at the end)
#
# Optional variables (the default fits almost everyone):
#   IPSIO_APP        where the app lives   (~/Applications/Ipsio.app)
#   IPSIO_BUNDLE_ID  app identifier        (io.github.shipsfromrio.ipsio)
#   IPSIO_CERT       signing certificate   ("Ipsio Dev", from certificate.sh)
# Changing BUNDLE_ID or CERT makes macOS ask again for the Screen Recording
# and Microphone permissions.
#
# SIGNING: the permissions (TCC) are bound to the app's designated requirement.
# Signed "ad hoc", the requirement is the cdhash, which changes on every
# build, and the permission vanishes silently (measured: after a few rebuilds
# the app said "permission missing" with the switch on in Settings). Signed
# with its own certificate, the requirement becomes `identifier + certificate
# leaf`, stable across builds. Without the certificate it falls back to ad hoc
# and says so.
set -e
cd "$(dirname "$0")"
APP="${IPSIO_APP:-$HOME/Applications/Ipsio.app}"
BID="${IPSIO_BUNDLE_ID:-io.github.shipsfromrio.ipsio}"
IDENT="${IPSIO_CERT:-Ipsio Dev}"
LABEL=io.github.shipsfromrio.ipsio
DIR="$HOME/.ipsio"
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

# Fail closed: reinstalling swaps ipsio.sh and restarts the app; in the middle
# of a recording that gains nothing and may lose its end.
if [ -f "$DIR/pid" ] && kill -0 "$(cat "$DIR/pid")" 2>/dev/null; then
  echo "REFUSED: an Ipsio recording is in progress. Stop it and run again."; exit 1; fi

mkdir -p "$DIR" && chmod 700 "$DIR"
[ -f "$DIR/calendar.url" ] && chmod 600 "$DIR/calendar.url"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Ipsio reads your meetings from the Calendar app to record them at the right time. Nothing leaves the Mac. / O Ipsio lê as reuniões do app Calendário para gravá-las na hora certa. Nada sai do Mac.</string>
  <key>NSCalendarsUsageDescription</key><string>Ipsio reads your meetings from the Calendar app to record them at the right time. Nothing leaves the Mac. / O Ipsio lê as reuniões do app Calendário para gravá-las na hora certa. Nada sai do Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>Ipsio records the computer sound (through BlackHole) and, in meeting mode, your voice. / O Ipsio grava o som do computador (pelo BlackHole) e, no modo reunião, a sua voz.</string>
</dict></plist>
PLIST
echo "== icon =="
if [ -f icon.png ]; then
  T=$(mktemp -d)/Ipsio.iconset; mkdir -p "$T"
  for n in 16 32 128 256 512; do
    sips -z $n $n icon.png --out "$T/icon_${n}x${n}.png" >/dev/null
    sips -z $((n*2)) $((n*2)) icon.png --out "$T/icon_${n}x${n}@2x.png" >/dev/null
  done
  iconutil -c icns "$T" -o "$APP/Contents/Resources/Ipsio.icns"
  rm -rf "$(dirname "$T")"
else
  echo "no icon.png in the folder; the app keeps the generic icon"
fi
echo "== recipe =="
cp ipsio.sh "$APP/Contents/Resources/ipsio.sh" && chmod +x "$APP/Contents/Resources/ipsio.sh"
echo "== building =="
# Into a temporary folder first: a failed build must not leave the KeepAlive
# LaunchAgent pointing at a deleted binary.
B=$(mktemp -d)
swiftc -O -parse-as-library app/Schedule.swift app/MacCalendar.swift app/Setup.swift app/SetupWindow.swift app/Ipsio.swift -framework AppKit -o "$B/Ipsio" 2>&1 | grep -v warning || true
swiftc -O -parse-as-library app/Schedule.swift app/MacCalendar.swift app/CalendarCLI.swift -o "$B/ipsio-calendar" 2>&1 | grep -v warning || true
# Inside the app, so the setup window's "Create" button needs no Terminal.
swiftc -O tools/create-device.swift -o "$B/create-device" 2>&1 | grep -v warning || true
[ -x "$B/Ipsio" ] && [ -x "$B/ipsio-calendar" ] && [ -x "$B/create-device" ] || { rm -rf "$B"; echo "build failed; the installed app was left as it was"; exit 1; }
mv -f "$B/Ipsio" "$B/ipsio-calendar" "$B/create-device" "$APP/Contents/MacOS/" && rm -rf "$B"
echo "== signing =="
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENT\""; then SIGN="$IDENT"
else SIGN="-"; echo "WARNING: no '$IDENT' certificate, signing ad hoc; permissions are lost on every rebuild. Run: bash certificate.sh"; fi
codesign -s "$SIGN" --force -i "$BID.calendar" "$APP/Contents/MacOS/ipsio-calendar" 2>&1 | grep -v "replacing existing" || true
codesign -s "$SIGN" --force -i "$BID.create-device" "$APP/Contents/MacOS/create-device" 2>&1 | grep -v "replacing existing" || true
codesign -s "$SIGN" --force "$APP" 2>&1 | grep -v "replacing existing" || true
codesign --verify --strict "$APP" || { echo "invalid signature"; exit 1; }
codesign -dr - "$APP" 2>&1 | tail -1
touch "$APP"   # Finder and Spotlight reread the icon
echo "== Terminal shortcuts =="
if ! grep -q 'alias ipsio-calendar=' ~/.zshrc 2>/dev/null; then
  cat >> ~/.zshrc <<ALIASES

# Ipsio
alias ipsio='bash "$APP/Contents/Resources/ipsio.sh"'
alias ipsio-calendar='"$APP/Contents/MacOS/ipsio-calendar"'
ALIASES
fi
echo "== LaunchAgent =="
LA=~/Library/LaunchAgents/$LABEL.plist
mkdir -p ~/Library/LaunchAgents
cat > "$LA" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Ipsio</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Ipsio 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA"
sleep 2
pgrep -x Ipsio >/dev/null && echo "Ipsio RUNNING: look for the circle next to the clock" || { echo "did not start; see: launchctl print gui/$(id -u)/$LABEL"; exit 1; }
