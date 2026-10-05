#!/bin/bash
# test-ipsio.sh: test bench for ipsio.sh with doubles for ffmpeg,
# SwitchAudioSource, screencapture, df and friends. Runs on Linux (CI) and on
# the Mac, with no BlackHole, no screen and no permission at all. Exits 1 if any
# assertion fails.
#
# What it proves, and why each item exists:
# - preflight REFUSES with a verdict (fail closed), one case per refusal;
# - the microphone is found by EXACT name and in the audio section
#   ("Microphone" must not match "iPhone Microphone");
# - a microphone delivering digital silence, or no sample at all, becomes
#   microphone=DEAD at start, in level and at stop, without stopping the recording;
# - stop restores the sound output and summarizes the recording from the meter;
# - every text key exists in both languages.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../ipsio.sh"
FAILS=0; TOTAL=0
ok() { TOTAL=$((TOTAL+1)); echo "ok   $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILS=$((FAILS+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
has() { case "$2" in *"$3"*) ok "$1";; *) fail "$1" "expected '$3' in: $(printf '%s' "$2" | tr '\n' '|')";; esac; }
lacks() { case "$2" in *"$3"*) fail "$1" "did not expect '$3' in: $(printf '%s' "$2" | tr '\n' '|')";; *) ok "$1";; esac; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }

# --------------------------------------------------------------- doubles ---
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ipsio-test.XXXXXX")
trap 'pkill -f "sleep 1 while 1" 2>/dev/null; rm -rf "$ROOT"' EXIT
STUB="$ROOT/stub"; BIN="$ROOT/bin"; mkdir -p "$STUB" "$BIN"
export STUB

cat > "$BIN/ffmpeg" <<'EOF'
#!/bin/bash
# Double: lists devices from $STUB/devices; when recording, writes samples to
# the meter files (file=...) and stays alive until signalled.
for a in "$@"; do [ "$a" = "-list_devices" ] && { cat "$STUB/devices" >&2; exit 1; }; done
echo "$*" > "$STUB/ffmpeg-args"
for a in "$@"; do
  # Pure bash, no fork per argument: forks are slow on some hosts, and stop
  # must not catch the double before it has written the meters.
  case "$a" in *.mkv) printf 'mkv' > "$a";; *file=*) ;; *) continue;; esac
  files=(); rest="$a"
  while [[ "$rest" =~ file=([^][\;,]+)(.*) ]]; do files+=("${BASH_REMATCH[1]}"); rest="${BASH_REMATCH[2]}"; done
  for f in "${files[@]}"; do
    v=; case "$f" in *level-mic) read -r v < "$STUB/mic";; *) read -r v < "$STUB/sys";; esac 2>/dev/null
    : > "$f"
    if [ -n "$v" ]; then for i in 1 2 3 4 5; do printf 'frame:%s pts:0 pts_time:%s\nlavfi.astats.Overall.RMS_level=%s\n' "$i" "$i" "$v" >> "$f"; done; fi
  done
done
echo "frame=  10 fps=12 time=00:00:05.00 bitrate=1k" >&2
exec perl -e '$SIG{INT}=sub{exit 0}; $SIG{TERM}=sub{exit 0}; sleep 1 while 1'
EOF
cat > "$BIN/ffprobe" <<'EOF'
#!/bin/bash
case "$*" in *format=duration*) echo 12.5;; *codec_name*) echo codec_name=aac;; esac
EOF
cat > "$BIN/SwitchAudioSource" <<'EOF'
#!/bin/bash
case "$*" in
  "-a -t output") cat "$STUB/outputs";;
  "-c -t output") cat "$STUB/current_output";;
  "-c -t input") cat "$STUB/input";;
  -t\ output\ -s\ *) printf '%s\n' "$4" > "$STUB/current_output";;
  "-a") cat "$STUB/outputs";;
esac
EOF
cat > "$BIN/screencapture" <<'EOF'
#!/bin/bash
[ -f "$STUB/no_permission" ] && exit 0
for a in "$@"; do d="$a"; done; printf 'png' > "$d"
EOF
cat > "$BIN/df" <<'EOF'
#!/bin/bash
printf 'Filesystem 1G-blocks Used Available Capacity Mounted\n/dev/x 900 100 %s 10%% /\n' "$(cat "$STUB/free")"
EOF
printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$BIN/pmset"
printf '#!/bin/bash\nexit 0\n' > "$BIN/caffeinate"
printf '#!/bin/bash\nexit 0\n' > "$BIN/say"
printf '#!/bin/bash\nexit 1\n' > "$BIN/defaults"
# ps: "-p PID -o args=" answers like the real one for the recorder double
# (an ffmpeg), or as a stranger when $STUB/foreign exists (pid reused).
cat > "$BIN/ps" <<'EOF'
#!/bin/bash
[ "$1" = "-p" ] || exit 1
kill -0 "$2" 2>/dev/null || exit 1
if [ -f "$STUB/foreign" ]; then echo "/usr/sbin/someone-else"; else echo "/opt/homebrew/bin/ffmpeg -nostdin"; fi
EOF
# date: a fixed minute when $STUB/now exists, so a name collision is not a race.
cat > "$BIN/date" <<'EOF'
#!/bin/bash
[ -f "$STUB/now" ] && [ "$1" = "+%Y-%m-%d_%H-%M" ] && exec cat "$STUB/now"
exec /bin/date "$@"
EOF
chmod +x "$BIN"/*

# scenario: clean state and a "good" Mac (everything present).
scenario() {
  rm -rf "${ROOT:?}/home" "${STUB:?}"/*; mkdir -p "$ROOT/home/.ipsio" "$STUB"
  cat > "$STUB/devices" <<'EOF'
[AVFoundation indev @ 0x1] AVFoundation video devices:
[AVFoundation indev @ 0x1] [0] FaceTime HD Camera
[AVFoundation indev @ 0x1] [1] Capture screen 0
[AVFoundation indev @ 0x1] AVFoundation audio devices:
[AVFoundation indev @ 0x1] [0] BlackHole 2ch
[AVFoundation indev @ 0x1] [1] iPhone Microphone
[AVFoundation indev @ 0x1] [2] MacBook Pro Microphone
EOF
  printf 'MacBook Pro Speakers\nBlackHole 2ch\nIpsio\n' > "$STUB/outputs"
  echo "MacBook Pro Speakers" > "$STUB/current_output"
  echo "MacBook Pro Microphone" > "$STUB/input"
  echo 500 > "$STUB/free"
  echo "-25.0" > "$STUB/sys"; echo "-55.0" > "$STUB/mic"
  conf
}
# run <subcommand> [VAR=value...]: the script with a bench HOME and PATH.
run() {
  local sub="$1"; shift
  env -i HOME="$ROOT/home" PATH="$BIN:/usr/bin:/bin" STUB="$STUB" TMPDIR="$ROOT" "$@" bash "$SCRIPT" "$sub" 2>&1
}
# conf [lines...]: the conf file; Portuguese unless a line sets UI_LANGUAGE.
conf() { { printf '%s\n' "$@"; case "$*" in *UI_LANGUAGE=*) ;; *) echo "UI_LANGUAGE='pt'";; esac; } > "$ROOT/home/.ipsio/conf"; }

# -------------------------------------------------------------- preflight ---
scenario; sed -i.bak '/BlackHole/d' "$STUB/devices"
has "no BlackHole refuses" "$(run start)" "verdict=NO_BLACKHOLE"

scenario; sed -i.bak '/Capture screen/d' "$STUB/devices"
has "no screen refuses" "$(run start)" "verdict=NO_SCREEN"

scenario; printf 'MacBook Pro Speakers\nBlackHole 2ch\n' > "$STUB/outputs"
has "missing output device refuses" "$(run start)" "verdict=MISSING_DEVICE"

scenario; echo 3 > "$STUB/free"
has "disk below the minimum refuses" "$(run start)" "verdict=DISK_FULL free_gb=3"

scenario; touch "$STUB/no_permission"
has "no screen permission refuses" "$(run start)" "verdict=NO_PERMISSION"

scenario
has "state folder with a space refuses" "$(run start IPSIO_DIR="$ROOT/with space")" "verdict=INVALID_DIR"

scenario; conf "MODE='meeting'"; echo "BlackHole 2ch" > "$STUB/input"
has "meeting with the default input on BlackHole refuses" "$(run start)" "verdict=MICROPHONE_IS_BLACKHOLE"

scenario; conf "MODE='meeting'" "MICROPHONE='Microphone that does not exist'"
has "meeting with a missing microphone refuses" "$(run start)" "verdict=NO_MICROPHONE"

scenario; conf "MODE='meeting'" "MICROPHONE='Microphone'"
has "microphone by exact name (no substring match)" "$(run start)" "verdict=NO_MICROPHONE"

scenario; conf "MODE='class'" "MICROPHONE='Microphone that does not exist'"
lacks "class ignores the microphone" "$(run start)" "NO_MICROPHONE"
run stop >/dev/null

# ------------------------------------------------------ meeting, live mic ---
scenario; conf "MODE='meeting'"
S=$(run start)
has "meeting records" "$S" "verdict=RECORDING mode=meeting microphone=OK"
has "meeting opens the default input by the right index" "$(cat "$STUB/ffmpeg-args")" "-i :2"
has "meeting has a microphone meter" "$(cat "$STUB/ffmpeg-args")" "level-mic"
same "start switches the output to Ipsio's device" "$(cat "$STUB/current_output")" "Ipsio"
N=$(run level)
has "level in a meeting reports the microphone" "$N" "mic=-55.0 mic_silence=0"
S=$(run stop)
has "stop saves" "$S" "verdict=SAVED sound=OK"
has "stop summarizes the microphone" "$S" "microphone=OK"
same "stop restores the sound output" "$(cat "$STUB/current_output")" "MacBook Pro Speakers"
[ -f "$ROOT/home/.ipsio/pid" ] && fail "stop removes the pid file" || ok "stop removes the pid file"

# ------------------------------------------ meeting, digitally silent mic ---
scenario; conf "MODE='meeting'"; echo "-inf" > "$STUB/mic"
S=$(run start)
has "a -inf microphone still records" "$S" "verdict=RECORDING"
has "a -inf microphone is DEAD at start" "$S" "microphone=DEAD"
has "start title says the microphone is dead" "$(printf '%s' "$S" | head -1)" "MICROFONE ESTÁ MUDO"
has "level counts the seconds of dead microphone" "$(run level)" "mic_silence=5"
S=$(run stop)
has "stop flags the dead microphone" "$S" "microphone=DEAD"
has "stop title says the microphone was dead" "$(printf '%s' "$S" | head -1)" "MICROFONE FICOU MUDO"

# ----------------------------------- meeting, microphone meter with no sample ---
scenario; conf "MODE='meeting'"; : > "$STUB/mic"
S=$(run start)
has "a silent microphone meter counts as DEAD (fail closed)" "$S" "microphone=DEAD"
has "level with a silent meter counts the whole time as dead" "$(run level)" "mic_silence=5"
run stop >/dev/null

# ------------------------------------------------------ class and overrides ---
scenario; conf "MODE='meeting'" "TITLE='Conf'"; echo "2026-01-02_03-04" > "$STUB/now"
S=$(run start IPSIO_MODE=class IPSIO_TITLE='Reunião: a/b')
has "IPSIO_MODE overrides the conf" "$S" "mode=class"
has "calendar title goes into the name, with no / or :" "$S" "Reunião- a-b.mkv"
lacks "class opens no microphone meter" "$(cat "$STUB/ffmpeg-args")" "level-mic"
lacks "level in class says nothing about the microphone" "$(run level)" "mic="
run stop >/dev/null
S=$(run start IPSIO_TITLE='Reunião: a/b')
has "same minute and same title does not overwrite" "$S" "2026-01-02_03-04 Reunião- a-b (2).mkv"
run stop >/dev/null

scenario; echo "-inf" > "$STUB/sys"
run start >/dev/null
S=$(run stop)
has "an entirely silent recording is SILENT" "$S" "sound=SILENT"
has "title says silent" "$(printf '%s' "$S" | head -1)" "MAS MUDA"

scenario
has "already recording refuses a second start" "$(run start >/dev/null; run start)" "verdict=ALREADY_RECORDING"
run stop >/dev/null

# A pid file left by a power cut, its number now owned by another process:
# not "recording", start goes ahead, and stop never signals the stranger.
scenario
run start >/dev/null
P=$(cat "$ROOT/home/.ipsio/pid"); touch "$STUB/foreign"
has "a reused pid is not a recording" "$(run status)" "parado"
run stop >/dev/null
if kill -0 "$P" 2>/dev/null; then ok "stop does not kill a process that is not the recorder"; else fail "stop does not kill a process that is not the recorder" "pid $P was killed"; fi
kill "$P" 2>/dev/null; rm -f "$STUB/foreign"

# Meeting: the main meter reads the COMPUTER branch, never the mix (on the
# mix your voice would hide a silent BlackHole).
scenario; conf "MODE='meeting'"
run start >/dev/null
has "meeting meter reads the computer branch" "$(cat "$STUB/ffmpeg-args")" "[s3]asetnsamples"
lacks "meeting meter does not read the mix" "$(cat "$STUB/ffmpeg-args")" "[met]"
run stop >/dev/null

scenario; echo "Ipsio" > "$STUB/current_output"
run start >/dev/null; run stop >/dev/null
same "original output on Ipsio itself goes back to a real output" "$(cat "$STUB/current_output")" "MacBook Pro Speakers"

scenario; conf "UI_LANGUAGE='en'" "MODE='meeting'"; echo "-inf" > "$STUB/mic"
S=$(run start)
has "in English the title is in English" "$(printf '%s' "$S" | head -1)" "MICROPHONE IS DEAD"
has "in English the machine line is the same" "$S" "microphone=DEAD"
run stop >/dev/null

scenario; rm -f "$ROOT/home/.ipsio/conf"
has "with no conf and no system language, English" "$(run start)" "RECORDING"
run stop >/dev/null

# ------------------------------------------------------------------ doctor ---
# doctor runs every check without stopping at the first one, records nothing,
# and its exit code tells a complete setup from an incomplete one.
scenario
D=$(run doctor); rc=$?
has "doctor on a good Mac is SETUP_OK" "$D" "verdict=SETUP_OK mode=class missing= ok="
has "doctor names every item it found OK, by key" "$D" "ok=dir,ffmpeg,blackhole,screen,switchaudio,device,folder,disk,permission calendar=none"
same "doctor on a good Mac exits 0" "$rc" "0"
if [ -e "$ROOT/home/.ipsio/pid" ] || [ -e "$STUB/ffmpeg-args" ]; then fail "doctor records nothing"; else ok "doctor records nothing"; fi

scenario
has "doctor refuses a state folder that start would refuse" "$(run doctor IPSIO_DIR="$ROOT/with space")" "missing=dir"

scenario; sed -i.bak '/BlackHole/d' "$STUB/devices"; touch "$STUB/no_permission"
D=$(run doctor); rc=$?
has "doctor lists every missing item, not only the first" "$D" "missing=blackhole,permission"
has "doctor keeps the found items apart from the missing ones" "$D" "ok=dir,ffmpeg,screen,"
has "doctor explains the BlackHole item" "$D" "X   O driver de áudio BlackHole"
has "doctor explains the permission item" "$D" "X   O macOS não deixa"
same "doctor incomplete exits 1" "$rc" "1"

scenario; conf "MODE='meeting'"; echo "Headset" > "$STUB/input"
has "doctor in meeting mode checks the microphone" "$(run doctor)" "missing=microphone"

scenario; conf "MODE='meeting'"
has "doctor in meeting mode with a good microphone is OK" "$(run doctor)" "verdict=SETUP_OK mode=meeting missing= ok=dir,ffmpeg,blackhole,screen,microphone,"

scenario; printf 'MacBook Pro Speakers\n' > "$STUB/outputs"; echo 3 > "$STUB/free"
has "doctor checks the output device and the disk" "$(run doctor)" "missing=device,disk"

scenario; mkdir -p "$ROOT/bin2"; cp "$BIN"/* "$ROOT/bin2/"; rm -f "$ROOT/bin2/ffmpeg" "$ROOT/bin2/SwitchAudioSource"
D=$(run doctor PATH="$ROOT/bin2:/usr/bin:/bin")
if (PATH="$ROOT/bin2:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"; command -v ffmpeg >/dev/null 2>&1 || command -v SwitchAudioSource >/dev/null 2>&1); then ok "doctor without ffmpeg (skipped: this host has the real tools)"
else has "doctor without ffmpeg or SwitchAudioSource says so" "$D" "missing=ffmpeg,switchaudio"; fi

scenario; conf "MODE='meeting'"; mkdir -p "$ROOT/bin3"; cp "$BIN"/* "$ROOT/bin3/"; rm -f "$ROOT/bin3/SwitchAudioSource"
D=$(run doctor PATH="$ROOT/bin3:/usr/bin:/bin")
if (PATH="$ROOT/bin3:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"; command -v SwitchAudioSource >/dev/null 2>&1); then ok "doctor without SwitchAudioSource blames no microphone (skipped: this host has the real tools)"
else has "doctor without SwitchAudioSource blames no microphone" "$D" "missing=switchaudio "; fi

scenario; echo "https://example.com/x.ics" > "$ROOT/home/.ipsio/calendar.url"; conf "CALENDAR_COMMAND='true'" "UI_LANGUAGE='en'"
D=$(run doctor)
has "doctor reports the connected calendar sources" "$D" "calendar=ics,command"
lacks "doctor never prints the calendar address" "$D" "example.com"
has "doctor speaks English when asked" "$D" "SETUP COMPLETE"

# ---------------------------------------------------------- pure functions ---
# shellcheck source=/dev/null
IPSIO_ONLY_FUNCTIONS=1 HOME="$ROOT/home" . "$SCRIPT"
same "classify -inf" "$(classify -inf)" "NO_SOUND"
same "classify -70" "$(classify -70)" "NO_SOUND"
same "classify -40" "$(classify -40)" "LOW"
same "classify -20" "$(classify -20)" "OK"
same "classify -5" "$(classify -5)" "LOUD"
sample() { for v in "$@"; do printf 'lavfi.astats.Overall.RMS_level=%s\n' "$v"; done; }
sample -20 -20 -20 -20 -20 -20 -20 -20 -20 -inf > "$ROOT/a"
same "10% silence is OK" "$(sound_summary "$ROOT/a")" "OK 10 -20.0"
sample -20 -20 -20 -20 -20 -inf -inf -inf -inf -inf > "$ROOT/a"
same "50% silence is GAPS" "$(sound_summary "$ROOT/a")" "GAPS 50 -20.0"
sample -inf -inf -inf -inf -inf -inf -inf -inf -inf -20 > "$ROOT/a"
same "90% silence is SILENT" "$(sound_summary "$ROOT/a")" "SILENT 90 -20.0"
: > "$ROOT/a"
same "no samples is NO_MEASURE" "$(sound_summary "$ROOT/a")" "NO_MEASURE 0 -99"
sample -60 -62 -58 -70 > "$ROOT/a"
same "room noise (-60) is NOT a dead microphone" "$(mic_summary "$ROOT/a")" "OK 0"
sample -inf -91 -85 -inf > "$ROOT/a"
same "below -80 is a dead microphone" "$(mic_summary "$ROOT/a")" "DEAD 100"
sample -30 -inf -inf -inf > "$ROOT/a"
same "trailing_silence counts only the end" "$(trailing_silence "$ROOT/a" -80)" "3"

# --------------------------------------------------------------- languages ---
EN=$(awk '/if \[ "\$L" = "en" \]; then case/{f=1;next} /esac; else case/{f=0} f && /^    [a-z_]+\)/{sub(/^ +/,""); sub(/\).*/,""); print}' "$SCRIPT" | sort)
PT=$(awk '/esac; else case/{f=1;next} /esac; fi/{f=0} f && /^    [a-z_]+\)/{sub(/^ +/,""); sub(/\).*/,""); print}' "$SCRIPT" | sort)
same "the same text keys in pt and en" "$EN" "$PT"
USED=$(grep -oE '(^|[;( ])t [a-z_]+' "$SCRIPT" | sed -E 's/.*t //' | sort -u)
MISSING=$(comm -23 <(printf '%s\n' "$USED") <(printf '%s\n' "$PT"))
same "every key used exists" "$MISSING" ""
[ "$(printf '%s\n' "$PT" | wc -l)" -gt 40 ] && ok "key extraction found the block" || fail "key extraction found the block"

# ------------------------------------------------------------------ popups ---
# A popup opened inside a DispatchQueue.main block holds the main queue until
# the click, and the calendar's next meetings never start (measured 05/10/2026).
# runModal may only live in modal() (which opens through perform(selector)) or
# in an action fired straight by a menu click.
APP="$HERE/../app/Ipsio.swift"
BAD=$(awk '/func [A-Za-z]+\(/{ match($0, /func [A-Za-z]+/); f=substr($0, RSTART+5, RLENGTH-5) }
  /runModal\(\)/ && f !~ /^(modal|doTitle|doFolder|doConnectCalendar)$/ { print f ":" NR }' "$APP")
same "popups open only through modal() or a menu click" "$BAD" ""
grep -q 'perform(#selector(self.runPendingModal)' "$APP" && ok "modal() opens through perform(selector)" || fail "modal() opens through perform(selector)"

# ------------------------------------------------------------- app texts ---
# A key repeated in a Swift dictionary literal crashes the app at launch, and a
# key missing in one language shows the raw key on screen.
swkeys() { sed -n "/let $1: \[String: String\] = \[/,/^        \]/p" "$APP" | grep -oE '"[a-z][a-zA-Z0-9_]*": "' | sed -E 's/^"//; s/": "$//'; }
SPT=$(swkeys pt | sort); SEN=$(swkeys en | sort)
same "app texts: no key repeated in pt" "$(printf '%s\n' "$SPT" | uniq -d)" ""
same "app texts: no key repeated in en" "$(printf '%s\n' "$SEN" | uniq -d)" ""
same "app texts: the same keys in pt and en" "$SPT" "$SEN"
[ "$(printf '%s\n' "$SPT" | wc -l)" -gt 80 ] && ok "app text extraction found the dictionaries" || fail "app text extraction found the dictionaries"
# Every setup item and every fix button has its text.
for k in $(grep -oE '"(script|dir|ffmpeg|switchaudio|blackhole|device|screen|screen_permission|mic_permission|microphone|folder|disk|calendar)"' "$HERE/../app/Setup.swift" | tr -d '"' | sort -u); do
  printf '%s\n' "$SPT" | grep -qx "setup_$k" && printf '%s\n' "$SPT" | grep -qx "setup_${k}_hint" || fail "setup item '$k' has a title and a hint"
done
ok "every setup item has a title and a hint"
for k in $(grep -oE 'return "fix_[a-z]+"' "$APP" | sed -E 's/return "//; s/"$//'); do
  printf '%s\n' "$SPT" | grep -qx "$k" || fail "fix button '$k' has a text"
done
ok "every fix button has a text"

echo
echo "$((TOTAL-FAILS))/$TOTAL ok"
[ "$FAILS" -eq 0 ]
