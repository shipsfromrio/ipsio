#!/bin/bash
# frame.sh <shot.png> <out.png>: centers a screenshot on a 2880x1800 canvas
# (the Mac App Store size), shrinking it only when it does not fit.
set -e
in="$1"; out="$2"
[ -f "$in" ] && [ -n "$out" ] || { echo "usage: frame.sh <shot.png> <out.png>"; exit 2; }
W=2880; H=1800
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cp "$in" "$T/s.png"
w=$(sips -g pixelWidth "$T/s.png" | awk '/pixelWidth/{print $2}')
h=$(sips -g pixelHeight "$T/s.png" | awk '/pixelHeight/{print $2}')
# Leave a margin of 160 px around the shot.
if [ "$w" -gt $((W - 320)) ] || [ "$h" -gt $((H - 320)) ]; then
  sips -Z $(( (W - 320) < (H - 320) ? (W - 320) : (H - 320) )) "$T/s.png" >/dev/null
fi
mkdir -p "$(dirname "$out")"
sips --padToHeightWidth $H $W --padColor EDEDED "$T/s.png" --out "$out" >/dev/null
sips -g pixelWidth -g pixelHeight "$out" | tail -2
