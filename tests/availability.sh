#!/bin/bash
# availability.sh: the app ships for macOS 13.0 (LSMinimumSystemVersion,
# -target *-apple-macos13.0) and nobody here has a 13 or 14 Mac. swiftc at
# -target macos13.0 already refuses most unguarded newer APIs; this cheap
# grep is the second net, for CI runners without the right SDK and for the
# symbols whose misuse compiles but misbehaves.
#
# Fails when a symbol of macOS 14, 15 or 26 appears in app/ without an
# "#available(macOS N" / "@available(macOS N" (N at least the symbol's
# version) on the same line or in the 15 lines before it, or inside a
# declaration marked "@available(macOS N, *)" (until its closing brace at
# the same indentation). A guard does not leak past the next "func"/"init"
# line. Comment lines and string literals are ignored.
#
# Usage: bash tests/availability.sh [folder]   (default: app/)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:-$HERE/../app}"
WINDOW=15

# min-OS <TAB> extended regex (awk). One per line; keep the regex narrow
# enough that a same-named property of another class does not match.
# (A function, not $(cat <<...): bash 3.2 on macOS misparses parens in a
# heredoc inside $(...).)
symbols() { cat <<'LIST'
14	SCContentSharingPicker
14	SCScreenshotManager
14	SCShareableContentInfo
14	SCShareableContent\.info\(
14	\.pointPixelScale
14	\.contentRect([^(A-Za-z]|$)
14	ignoreShadowsSingleWindow
14	presenterOverlayPrivacyAlertSetting
14.2	includeChildWindows
14.4	getCurrentProcessShareableContent
14	requestFullAccessToEvents
14	requestFullAccessToReminders
14	requestWriteOnlyAccessToEvents
14	\.fullAccess([^A-Za-z]|$)
14	\.writeOnly([^A-Za-z]|$)
14	AVAudioApplication
14	NSMenuItem\.sectionHeader
14	activate\(\)
14	@Observable
15	captureMicrophone
15	microphoneCaptureDeviceID
15	SCStreamOutputType\.microphone
15	(type: *|== *)\.microphone([^A-Za-z(]|$)|case *\.microphone *:
15	SCRecordingOutput
15	showMouseClicks
15	captureDynamicRange
15	SCStreamConfiguration\(preset
15	import Synchronization
15	Mutex<
26	SpeechAnalyzer
26	SpeechTranscriber
26	DictationTranscriber
26	SpeechDetector
26	AssetInventory
26	AnalyzerInput
LIST
}
SYMBOLS=$(symbols)

FILES=$(find "$DIR" -type f -name '*.swift' | sort)
[ -n "$FILES" ] || { echo "availability: no .swift files under $DIR"; exit 1; }

# shellcheck disable=SC2086  # FILES is a newline list of paths without spaces
AV_SYMBOLS="$SYMBOLS" awk -v window="$WINDOW" '
function ver(s,   a, n) { n = split(s, a, "."); return a[1] * 100 + (n > 1 ? a[2] : 0) }
# The highest macOS version an "#available(macOS N" / "@available(macOS N" on this line grants.
function grants(s,   best, v, rest) {
  best = 0; rest = s
  while (match(rest, /[#@]available\(macOS [0-9]+(\.[0-9]+)?/)) {
    v = substr(rest, RSTART, RLENGTH); sub(/.*macOS /, "", v)
    if (ver(v) > best) best = ver(v)
    rest = substr(rest, RSTART + RLENGTH)
  }
  return best
}
function indent(s) { match(s, /^ */); return RLENGTH }
BEGIN {
  n = split(ENVIRON["AV_SYMBOLS"], rows, "\n")   # ENVIRON: the regexes keep their backslashes
  for (i = 1; i <= n; i++) { split(rows[i], f, "\t"); if (f[2] != "") { k++; need[k] = ver(f[1]); pat[k] = f[2]; label[k] = f[1] } }
  bad = 0
  if (k == 0) { blind = 1; exit 2 }                       # an empty list would pass anything
}
FNR == 1 { depth = 0; delete hist }
{
  line = $0
  if (line ~ /^[ \t]*\/\//) { code = "" }                 # comment line
  else {
    code = line
    gsub(/"([^"\\]|\\.)*"/, "\"\"", code)                 # string literals
    sub(/[ \t]\/\/ .*$/, "", code)                        # trailing comment
  }
  # A declaration closing at the indentation of its @available ends that scope.
  if (depth > 0 && code ~ /^ *}/ && indent(code) == sind[depth]) depth--
  # A new function starts with no guard: one in the function above does not cover it.
  if (code ~ /^[ 	]*((static|class|private|fileprivate|public|internal|final|override|mutating|nonisolated|@objc|@MainActor|@discardableResult)[ 	]+)*(func|init)[ 	(<]/)
    for (j = 0; j <= window; j++) hist[j] = 0
  g = grants(code)
  if (code ~ /^ *@available\(macOS / && g > 0) { depth++; sind[depth] = indent(code); sver[depth] = g }
  hist[FNR % (window + 1)] = g
  cover = 0
  for (d = 1; d <= depth; d++) if (sver[d] > cover) cover = sver[d]
  for (j = 0; j <= window && j < FNR; j++) { h = hist[(FNR - j) % (window + 1)]; if (h > cover) cover = h }
  for (i = 1; i <= k; i++) {
    if (code ~ pat[i] && cover < need[i]) {
      printf "%s:%d: macOS %s symbol /%s/ without #available/@available(macOS %s) nearby\n    %s\n", FILENAME, FNR, label[i], pat[i], label[i], line
      bad++
    }
  }
}
END {
  if (blind) { print "availability: the symbol list did not load"; exit 2 }
  if (bad) { printf "availability: %d unguarded use(s) of APIs newer than macOS 13.0\n", bad; exit 1 }
  print "availability: ok (every macOS 14/15/26 symbol in the list is guarded)"
}' $FILES
