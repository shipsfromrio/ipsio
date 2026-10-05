#!/bin/bash
# Sets up a Mac for Ipsio, from scratch. Run in the Mac's Terminal, in the
# repository folder:   bash install.sh
#
# 1. ffmpeg, switchaudio-osx and the BlackHole driver through Homebrew;
# 2. reloads the audio system (no need to restart the Mac);
# 3. creates in code the "Ipsio" output device (speaker + BlackHole);
# 4. creates the certificate that keeps the permissions across updates;
# 5. builds and starts the menu-bar app (install-app.sh).
#
# What it does NOT do, because macOS only allows it on screen: the Screen
# Recording and Microphone permissions. The app asks for both when it opens.
# It asks for the Mac's password (audio driver, audio reload and certificate).
set -e
cd "$(dirname "$0")"
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="$PATH:/opt/homebrew/bin:/usr/local/bin";; esac
DEVICE="${IPSIO_DEVICE:-Ipsio}"
# Fail closed, BEFORE anything: upgrading ffmpeg and restarting coreaudiod
# under a live capture would kill it.
if [ -f ~/.ipsio/pid ] && kill -0 "$(cat ~/.ipsio/pid)" 2>/dev/null; then
  echo "REFUSED: an Ipsio recording is in progress. Stop it and run again."; exit 1; fi
case "$DEVICE" in *"'"*) echo "IPSIO_DEVICE cannot contain an apostrophe"; exit 1;; esac
command -v brew >/dev/null || { echo "Homebrew missing: install it from https://brew.sh and run again"; exit 1; }
command -v swiftc >/dev/null || { echo "Command Line Tools missing: run xcode-select --install and then this script again"; exit 1; }
brew install ffmpeg switchaudio-osx
brew install --cask blackhole-2ch
echo
echo "== reloading audio (avoids restarting the Mac; asks for the password) =="
sudo killall coreaudiod || true
sleep 2
if SwitchAudioSource -a | grep -q 'BlackHole 2ch'; then
  echo "BLACKHOLE OK"
else
  echo "BlackHole has not shown up yet: restart the Mac and run this script again."; exit 1
fi
echo "== output device '$DEVICE' =="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -o "$T/create-device" tools/create-device.swift
"$T/create-device" "$DEVICE"
SwitchAudioSource -a -t output | grep -qxF "$DEVICE" || { echo "the device '$DEVICE' did not show up; see the README (create it by hand)"; exit 1; }
if [ "$DEVICE" != "Ipsio" ]; then
  mkdir -p ~/.ipsio
  grep -q '^OUTPUT_DEVICE=' ~/.ipsio/conf 2>/dev/null || echo "OUTPUT_DEVICE='$DEVICE'" >> ~/.ipsio/conf
fi
echo "== certificate =="
bash certificate.sh
echo "== app =="
bash install-app.sh
echo "== check =="
# Same checks the app runs from "Check setup". Run from here, the screen
# permission line reflects Terminal, not Ipsio: the app's own check is the one
# that counts for recordings.
bash ipsio.sh doctor || true
echo
echo "Done. Left to do, once:"
echo "  1. allow Microphone and Screen Recording when Ipsio asks;"
echo "  2. in Zoom/Teams, pick the speaker '$DEVICE';"
echo "  3. optional: in the Ipsio menu, 'Connect calendar…' to record meetings by themselves;"
echo "  4. in the Ipsio menu, 'Check setup', then 'Test now (20 s)'."
