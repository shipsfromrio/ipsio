#!/bin/bash
# Sets up a Mac for Ipsio, from scratch. Run in the Mac's Terminal, in the
# repository folder:   bash install.sh
#
# The app records by itself (ScreenCaptureKit, inside the app): no driver, no
# Homebrew, no sound device. By default this script only:
# 1. checks the Command Line Tools (swiftc builds the app);
# 2. creates the certificate that keeps the permissions across updates;
# 3. builds and starts the menu-bar app (install-app.sh).
#
#   bash install.sh --with-script
# also sets up the legacy Terminal recipe (ipsio.sh), which records through
# ffmpeg and BlackHole: ffmpeg, switchaudio-osx and the BlackHole driver
# through Homebrew, an audio reload, and the "Ipsio" output device
# (speaker + BlackHole). The app needs none of it.
#
# What it does NOT do, because macOS only allows it on screen: the Screen
# Recording and Microphone permissions. The app asks for them when it opens.
# It asks for the Mac's password once, for the certificate (with
# --with-script, also for the audio driver and the audio reload).
set -e
cd "$(dirname "$0")"
WITH_SCRIPT=0
for a in "$@"; do
  case "$a" in
    --with-script) WITH_SCRIPT=1;;
    *) echo "usage: bash install.sh [--with-script]"; exit 2;;
  esac
done
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="$PATH:/opt/homebrew/bin:/usr/local/bin";; esac
DEVICE="${IPSIO_DEVICE:-Ipsio}"
# Fail closed, BEFORE anything: reinstalling restarts the app, which ends the
# recording it holds; upgrading ffmpeg or restarting coreaudiod under the
# script's live capture would kill it.
if [ -f ~/.ipsio/pid ] && kill -0 "$(cat ~/.ipsio/pid)" 2>/dev/null; then
  echo "REFUSED: an Ipsio recording is in progress. Stop it and run again."; exit 1; fi
# The app keeps ~/.ipsio/recording while it records, and a crash leaves it behind
# next to the fragments of that recording.
if [ -f ~/.ipsio/recording ]; then
  echo "REFUSED: an Ipsio recording is in progress, or was left open by a crash."
  echo "Open Ipsio so it closes that recording (or stop it from the menu), then run again."; exit 1; fi
command -v swiftc >/dev/null || { echo "Command Line Tools missing: run xcode-select --install and then this script again"; exit 1; }
if [ "$WITH_SCRIPT" = 1 ]; then
  case "$DEVICE" in *"'"*) echo "IPSIO_DEVICE cannot contain an apostrophe"; exit 1;; esac
  command -v brew >/dev/null || { echo "Homebrew missing: install it from https://brew.sh and run again"; exit 1; }
  echo "== Terminal recipe: ffmpeg, switchaudio-osx, BlackHole =="
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
    mkdir -p ~/.ipsio && chmod 700 ~/.ipsio
    grep -q '^OUTPUT_DEVICE=' ~/.ipsio/conf 2>/dev/null || echo "OUTPUT_DEVICE='$DEVICE'" >> ~/.ipsio/conf
  fi
fi
echo "== certificate =="
bash certificate.sh
echo "== app =="
bash install-app.sh
if [ "$WITH_SCRIPT" = 1 ]; then
  echo "== Terminal recipe check =="
  # The script's own checks. Run from here, the screen permission line
  # reflects Terminal, not Ipsio.
  bash ipsio.sh doctor || true
fi
echo
echo "Done. Left to do, once:"
echo "  1. in the 'Set up Ipsio' window, click the button on each red line until all are green;"
echo "  2. in that window, 'Test now (20 s)'."
