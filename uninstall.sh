#!/bin/bash
# Removes the app and the LaunchAgent. Does NOT delete the recordings or
# ~/.ipsio (conf, calendar, cache); the output device, BlackHole, the
# certificate and the "# Ipsio" aliases in ~/.zshrc stay.
# Run: bash uninstall.sh
set -e
LABEL=io.github.shipsfromrio.ipsio
APP="${IPSIO_APP:-$HOME/Applications/Ipsio.app}"
if [ -f ~/.ipsio/pid ] && kill -0 "$(cat ~/.ipsio/pid)" 2>/dev/null; then
  echo "REFUSED: a recording is in progress. Stop it first."; exit 1; fi
if [ -f ~/.ipsio/recording ]; then
  echo "REFUSED: an Ipsio recording is in progress (or was cut short: open Ipsio so it closes it). Stop it first."; exit 1; fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f ~/Library/LaunchAgents/$LABEL.plist
pkill -x Ipsio 2>/dev/null || true
rm -rf "$APP"
echo "Ipsio removed. Recordings and ~/.ipsio stayed where they were."
