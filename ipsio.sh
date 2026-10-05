#!/bin/bash
# ipsio.sh: records the SCREEN + the COMPUTER SOUND (through BlackHole) and,
# in meeting mode, the MICROPHONE too, into a single .mkv.
# Usage: start | level | check | status | stop | test | doctor | folder | title |
#        output | device | language | mode | microphone
#
# Every recording rule lives here; the Ipsio app only calls subcommands and
# shows their output. Output speaks in two layers: first line = the verdict in
# words (the app uses it as the popup title), then the explanation, and last a
# technical-detail line with the numbers, because nobody knows what -20 dB is.
# It ends with ONE machine line, "#state key=value ...", identical in every
# language: that line, never the text, is what the app reads to pick icon and
# alarm.
#
# Language: UI_LANGUAGE='pt' or 'en' in the conf (default: the system language).
# Human text is translated; keys, file names and the #state line are not.
#
# Why it is built this way (each line is a measured incident; see README):
# - Shift+Cmd+5 recorded 8h23 / 228 GB with NO audio. macOS cannot capture
#   its own sound without a virtual driver (BlackHole).
# - With BlackHole installed, a whole morning came out SILENT (-91 dB): Zoom
#   picks its own speaker and ignores the system output. The speaker INSIDE
#   Zoom has to be Ipsio's output device. And the verdict measures VOLUME,
#   because "an audio stream exists" was the check that lied that day.
# - The LIVE meter (level subcommand) exists to catch that in 2 minutes, not
#   at lunch: the same ffmpeg that records writes the RMS of every second
#   (astats direct=1), with no second BlackHole reader (a second ffmpeg reading
#   the same device measured -inf while the first one was recording).
# - .mkv, not .mp4: an abrupt cut (battery, kill) leaves the .mkv readable.
# - -nostdin: without it, a background ffmpeg "eats" the script's stdin.
# - avfoundation indexes are found at run time, by EXACT name and in the right
#   section (video or audio), never hardcoded ("4:0" changed from Mac to Mac).
# - caffeinate tied to ffmpeg: a sleeping display records black, and system
#   sleep kills the capture (nearly happened 6h40 into a recording, on battery).
# - screencapture REFUSES a destination whose name starts with a dot and still
#   returns 0: the permission proof is the file existing with a size.
# - A microphone macOS will not open (permission denied, input at zero) does
#   not fail: it delivers DIGITAL silence, -inf. A real microphone has room
#   noise (-60 dB measured with nobody talking, -32 dB with a voice). So
#   "dead" is below -80 dB, not "nobody spoke".

# /opt/homebrew/bin (Apple Silicon) and /usr/local/bin (Intel) go at the END of
# PATH: launchd does not add them, and at the end they do not hide test doubles.
case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) PATH="$PATH:/opt/homebrew/bin";; esac
case ":$PATH:" in *:/usr/local/bin:*) ;; *) PATH="$PATH:/usr/local/bin";; esac
export PATH

DIR="${IPSIO_DIR:-$HOME/.ipsio}"
PIDFILE="$DIR/pid"
LEVEL="$DIR/level"
LEVEL_MIC="$DIR/level-mic"
LOG="$DIR/log"
FILEREC="$DIR/file"
MODEREC="$DIR/recording-mode"
ORIG_OUTPUT="$DIR/original-output"
# Configuration (the app writes it; editing by hand works too), shell format:
#   RECORDINGS_DIR='/Users/someone/Movies/Ipsio'
#   TITLE='Sample course'
#   MODE='class'                       (class = listen only; meeting = + microphone)
#   MICROPHONE='MacBook Pro Microphone' (empty = the system default input)
#   OUTPUT_DEVICE='Ipsio'
#   MIN_FREE_GB='20'
#   UI_LANGUAGE='pt'
# IPSIO_TITLE and IPSIO_MODE in the environment override the conf for ONE
# recording (that is how the app's calendar records a meeting under its name).
CONF="$DIR/conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
FOLDER="${RECORDINGS_DIR:-$HOME/Movies/Ipsio}"
TITLE=$(printf '%s' "${IPSIO_TITLE:-${TITLE:-}}" | tr '\n\r\t' '   ' | sed -E 's#[/:]#-#g; s/^ +| +$//g')
MODE="${IPSIO_MODE:-${MODE:-class}}"; [ "$MODE" = "meeting" ] || MODE=class
DEVICE="${OUTPUT_DEVICE:-Ipsio}"
MIN_GB="${MIN_FREE_GB:-20}"
MIC="${MICROPHONE:-}"
if [ -z "${UI_LANGUAGE:-}" ]; then
  case "$(defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n"(' | cut -c1-2)" in pt) UI_LANGUAGE=pt;; *) UI_LANGUAGE=en;; esac
fi
L="$UI_LANGUAGE"; [ "$L" = "en" ] || L=pt
# Thresholds, in dB of RMS (10 s average, one sample per second).
SILENCE_DB=-60      # computer sound below this = nobody talking there
MIC_DEAD_DB=-80     # microphone below this = a dead microphone, not silence

# t <key> [args...]: human text in the chosen language. Fixed keys.
t() {
  local k="$1"; shift
  if [ "$L" = "en" ]; then case "$k" in
    already_recording) echo "ALREADY RECORDING"; echo "A recording is in progress. Stop it before starting another.";;
    no_blackhole) echo "NO BLACKHOLE"; echo "The BlackHole audio driver is not among the devices. Run install.sh again or restart the Mac.";;
    no_screen) echo "NO SCREEN TO RECORD"; echo "ffmpeg did not find the screen (Capture screen 0).";;
    no_microphone) echo "NO MICROPHONE"; echo "Meeting mode needs the microphone '$1' and it is not among the devices. Pick another one in the Ipsio menu, or set MICROPHONE in $CONF.";;
    microphone_is_blackhole) echo "THE MICROPHONE IS BLACKHOLE"; echo "The system input is '$1', which is the recorder itself, not your voice. In System Settings > Sound > Input, choose the real microphone.";;
    microphone_dead_start) echo "RECORDING, BUT THE MICROPHONE IS DEAD"; echo "Screen and computer sound are being recorded to $1, but the microphone '$2' delivers digital silence: the macOS Microphone permission is missing, or the input volume is at zero. The others are being recorded; your voice is not.";;
    missing_device) echo "MISSING DEVICE $DEVICE"; echo "Create the multi-output device '$DEVICE' (run install.sh again, or Audio MIDI Setup).";;
    folder_inaccessible) echo "FOLDER NOT ACCESSIBLE"; echo "Could not create the folder $FOLDER";;
    invalid_dir) echo "INVALID STATE FOLDER"; echo "The folder $DIR has a character the recorder cannot use in its paths (space, colon, comma, quote, bracket). Point IPSIO_DIR to a simple path.";;
    disk_full) echo "DISK FULL"; echo "Only $1 GB free in $FOLDER, and a recording takes about 2 GB per hour. Free some space (configured minimum: ${MIN_GB} GB).";;
    no_permission) echo "NO SCREEN RECORDING PERMISSION"; echo "macOS does not let this program record the screen. In System Settings > Privacy & Security > Screen & System Audio Recording, enable Ipsio (or Terminal) and reopen it.";;
    battery_warning) echo "WARNING: the Mac is on BATTERY. An 8-hour recording will not fit; plug it in.";;
    did_not_start) echo "DID NOT START"; echo "The recorder died on startup. Last lines of the log:";;
    recording) echo "RECORDING"; echo "Screen and sound are being recorded to $1. In Zoom, Teams or Meet, keep Speaker = $DEVICE. Sound is checked automatically every second.";;
    recording_meeting) echo "RECORDING THE MEETING"; echo "Screen, the others and your voice (microphone '$2') are being recorded to $1. In Zoom, Teams or Meet, keep Speaker = $DEVICE.";;
    no_sound) echo "NO SOUND"; echo "The screen is recording, but NO sound is coming in. In Zoom, Teams or Meet, go to Audio and set Speaker = $DEVICE. Then check again.";;
    sound_low) echo "SOUND TOO LOW"; echo "There is sound, but weak. Raise the volume inside Zoom or Teams (not the keyboard) and check again.";;
    sound_loud) echo "SOUND TOO LOUD"; echo "It is coming in too loud and may distort. Lower the volume a bit inside Zoom or Teams.";;
    sound_ok) echo "SOUND OK"; echo "Screen and sound are coming in. Keep recording.";;
    microphone_dead) echo "Microphone dead for about $1 s (permission, mute or input volume at zero).";;
    not_recording) echo "NOT RECORDING"; echo "There is no recording in progress.";;
    measuring) echo "MEASURING"; echo "First seconds; sound is measured every second.";;
    silent_for) echo "Silent for about $1 s.";;
    no_track) echo "NO SOUND"; echo "The file has no audio track. Stop, check that BlackHole is among the devices, and record again.";;
    too_early) echo "TOO EARLY"; echo "Could not measure yet. Wait 1 minute of speech and check again.";;
    does_not_open) echo "FILE DOES NOT OPEN"; echo "$1 ended up with $2 but ffprobe cannot read its duration. Do not delete it: .mkv is usually recoverable (ffmpeg -i file -c copy new.mkv).";;
    saved) echo "RECORDING SAVED";;
    saved_silent) echo "RECORDING SAVED, BUT SILENT";;
    saved_gaps) echo "RECORDING SAVED, WITH SOUND GAPS";;
    saved_mic_dead) echo "RECORDING SAVED, BUT YOUR MICROPHONE WAS DEAD";;
    saved_body) echo "$1: $2, $3, $4. It is in $5.";;
    mic_sum_dead) printf "microphone DEAD %d%% of the time" "$1";;
    mic_sum_ok) echo "microphone OK";;
    was_not_recording) echo "NOT RECORDING"; echo "There was no recording in progress.";;
    test_no_video) echo "TEST FAILED: NO VIDEO"; echo "The file has no image. Check the Screen Recording permission.";;
    test_no_sound) echo "TEST FAILED: NO SOUND"; echo "The test sentence did not make it into the recording. Check that the Mac has sound and that the device $DEVICE exists.";;
    test_no_microphone) echo "TEST FAILED: MICROPHONE DEAD"; echo "Computer sound made it into the recording, but the microphone '$1' delivered digital silence. Check the Microphone permission (System Settings > Privacy & Security > Microphone) and the input volume.";;
    test_ok) echo "TEST OK"; echo "Screen and sound made it into the test recording. The test file was deleted. On the day, check Speaker in Zoom, Teams or Meet = $DEVICE.";;
    test_ok_meeting) echo "TEST OK (MEETING)"; echo "Screen, computer sound and the microphone '$1' made it into the test recording. The test file was deleted.";;
    detail) echo "technical detail: $*";;
    detail_start) echo "pid $1, system output $2, $3 GB free, caffeinate on, mode $4";;
    detail_level) echo "level now $1 dB, $2 recorded, $3, disk for another $4 GB (~$5 h)";;
    detail_mic) echo "microphone now $1 dB";;
    detail_check) echo "whole-file average $1 dB, peak $2 dB, $3 recorded, $4";;
    detail_stop) echo "Mac sound back to $1";;
    detail_test) echo "average $1 dB in the 10 s test";;
    detail_test_mic) echo "average $1 dB in the 10 s test, microphone $2 dB";;
    recorded) echo "$1 recorded, $2";;
    stopped) echo "stopped (nothing recording)";;
    sum_silent) printf "NO SOUND %d%% of the time (SILENT)" "$1";;
    sum_gaps) printf "sound only %d%% of the time (average %.0f dB)" "$1" "$2";;
    sum_low) printf "sound LOW (average %.0f dB)" "$1";;
    sum_ok) printf "sound OK (average %.0f dB, silence %d%% of the time)" "$1" "$2";;
    no_measure) echo "no measurement";;
    no_ffmpeg) echo "NO FFMPEG"; echo "ffmpeg is not installed. Run install.sh, or: brew install ffmpeg";;
    no_switchaudio) echo "NO SWITCHAUDIOSOURCE"; echo "SwitchAudioSource is not installed. Run install.sh, or: brew install switchaudio-osx";;
    doctor_ok) echo "SETUP COMPLETE"; echo "Everything Ipsio needs is in place.";;
    doctor_incomplete) echo "SETUP INCOMPLETE"; echo "Fix the items marked with X, then check again.";;
    doctor_item) echo "OK  $1";;
    doctor_calendar_none) echo "--  calendar: none connected (optional; menu > Connect calendar)";;
    doctor_calendar) echo "OK  calendar: $1";;
  esac; else case "$k" in
    already_recording) echo "JÁ ESTÁ GRAVANDO"; echo "Há uma gravação em andamento. Pare antes de começar outra.";;
    no_blackhole) echo "SEM BLACKHOLE"; echo "O driver de áudio BlackHole não aparece nos dispositivos. Rode o install.sh de novo ou reinicie o Mac.";;
    no_screen) echo "SEM TELA PARA GRAVAR"; echo "O ffmpeg não encontrou a tela (Capture screen 0).";;
    no_microphone) echo "SEM MICROFONE"; echo "O modo reunião precisa do microfone '$1' e ele não aparece nos dispositivos. Escolha outro no menu do Ipsio, ou ajuste MICROPHONE em $CONF.";;
    microphone_is_blackhole) echo "O MICROFONE É O BLACKHOLE"; echo "A entrada do sistema é '$1', que é o próprio gravador, não a sua voz. Em Ajustes do Sistema > Som > Entrada, escolha o microfone de verdade.";;
    microphone_dead_start) echo "GRAVANDO, MAS O MICROFONE ESTÁ MUDO"; echo "Tela e som do computador estão sendo gravados em $1, mas o microfone '$2' entrega silêncio digital: falta a permissão de Microfone do macOS, ou o volume de entrada está no zero. Os outros estão sendo gravados; a sua voz não.";;
    missing_device) echo "FALTA O DISPOSITIVO $DEVICE"; echo "Crie o dispositivo de saída múltipla '$DEVICE' (rode o install.sh de novo, ou Configuração de Áudio e MIDI).";;
    folder_inaccessible) echo "PASTA INACESSÍVEL"; echo "Não consegui criar a pasta $FOLDER";;
    invalid_dir) echo "PASTA DE ESTADO INVÁLIDA"; echo "A pasta $DIR tem um caractere que o gravador não aceita nos caminhos (espaço, dois-pontos, vírgula, aspas, colchete). Aponte IPSIO_DIR para um caminho simples.";;
    disk_full) echo "DISCO CHEIO"; echo "Só há $1 GB livres em $FOLDER, e uma gravação gasta cerca de 2 GB por hora. Libere espaço (mínimo configurado: ${MIN_GB} GB).";;
    no_permission) echo "SEM PERMISSÃO DE TELA"; echo "O macOS não deixa este programa gravar a tela. Em Ajustes do Sistema > Privacidade e Segurança > Gravação de Tela e Áudio do Sistema, ligue o Ipsio (ou o Terminal) e reabra.";;
    battery_warning) echo "AVISO: o Mac está na BATERIA. Uma gravação de 8 h não cabe; ligue na tomada.";;
    did_not_start) echo "NÃO COMEÇOU"; echo "O gravador morreu ao iniciar. Últimas linhas do log:";;
    recording) echo "GRAVANDO"; echo "Tela e som sendo gravados em $1. No Zoom, Teams ou Meet, deixe o alto-falante = $DEVICE. O som é conferido sozinho a cada segundo.";;
    recording_meeting) echo "GRAVANDO A REUNIÃO"; echo "Tela, os outros e a sua voz (microfone '$2') sendo gravados em $1. No Zoom, Teams ou Meet, deixe o alto-falante = $DEVICE.";;
    no_sound) echo "SEM SOM"; echo "A tela está gravando, mas o som NÃO está entrando. No Zoom, Teams ou Meet, vá em Áudio e escolha alto-falante = $DEVICE. Depois confira de novo.";;
    sound_low) echo "SOM BAIXO"; echo "Tem som, mas fraco. Suba o volume dentro do Zoom ou Teams (não o do teclado) e confira de novo.";;
    sound_loud) echo "SOM ALTO"; echo "Está entrando alto demais e pode distorcer. Abaixe um pouco o volume dentro do Zoom ou Teams.";;
    sound_ok) echo "SOM OK"; echo "Tela e som estão entrando. Pode deixar gravando.";;
    microphone_dead) echo "Microfone mudo há cerca de $1 s (permissão, mudo ou volume de entrada no zero).";;
    not_recording) echo "NADA GRAVANDO"; echo "Não há gravação em andamento.";;
    measuring) echo "MEDINDO"; echo "Primeiros segundos; o som é medido a cada segundo.";;
    silent_for) echo "Silêncio há cerca de $1 s.";;
    no_track) echo "SEM SOM"; echo "O arquivo não tem faixa de áudio. Pare, confira se o BlackHole aparece nos dispositivos e grave de novo.";;
    too_early) echo "AINDA CEDO"; echo "Ainda não deu para medir. Espere 1 minuto de fala e confira de novo.";;
    does_not_open) echo "ARQUIVO NÃO ABRE"; echo "$1 ficou com $2 mas o ffprobe não lê a duração. Não apague: o .mkv costuma ser recuperável (ffmpeg -i arquivo -c copy novo.mkv).";;
    saved) echo "GRAVAÇÃO SALVA";;
    saved_silent) echo "GRAVAÇÃO SALVA, MAS MUDA";;
    saved_gaps) echo "GRAVAÇÃO SALVA, COM FALHAS DE SOM";;
    saved_mic_dead) echo "GRAVAÇÃO SALVA, MAS O SEU MICROFONE FICOU MUDO";;
    saved_body) echo "$1: $2, $3, $4. Está em $5.";;
    mic_sum_dead) printf "microfone MUDO em %d%% do tempo" "$1";;
    mic_sum_ok) echo "microfone OK";;
    was_not_recording) echo "NADA GRAVANDO"; echo "Não havia gravação em andamento.";;
    test_no_video) echo "TESTE FALHOU: SEM VÍDEO"; echo "O arquivo saiu sem imagem. Confira a permissão de Gravação de Tela.";;
    test_no_sound) echo "TESTE FALHOU: SEM SOM"; echo "A frase de teste não entrou na gravação. Confira se o Mac está com som e se o dispositivo $DEVICE existe.";;
    test_no_microphone) echo "TESTE FALHOU: MICROFONE MUDO"; echo "O som do computador entrou na gravação, mas o microfone '$1' entregou silêncio digital. Confira a permissão de Microfone (Ajustes do Sistema > Privacidade e Segurança > Microfone) e o volume de entrada.";;
    test_ok) echo "TESTE OK"; echo "Tela e som entraram na gravação de teste. O arquivo de teste foi apagado. No dia, confira o alto-falante do Zoom, Teams ou Meet = $DEVICE.";;
    test_ok_meeting) echo "TESTE OK (REUNIÃO)"; echo "Tela, som do computador e o microfone '$1' entraram na gravação de teste. O arquivo de teste foi apagado.";;
    detail) echo "detalhe técnico: $*";;
    detail_start) echo "pid $1, saída do sistema $2, $3 GB livres, caffeinate ativo, modo $4";;
    detail_level) echo "nível agora $1 dB, $2 gravados, $3, disco para mais $4 GB (~$5 h)";;
    detail_mic) echo "microfone agora $1 dB";;
    detail_check) echo "média do arquivo inteiro $1 dB, pico $2 dB, $3 gravados, $4";;
    detail_stop) echo "som do Mac de volta para $1";;
    detail_test) echo "média $1 dB no teste de 10 s";;
    detail_test_mic) echo "média $1 dB no teste de 10 s, microfone $2 dB";;
    recorded) echo "gravados $1, $2";;
    stopped) echo "parado (nada gravando)";;
    sum_silent) printf "SEM SOM em %d%% do tempo (MUDA)" "$1";;
    sum_gaps) printf "som em só %d%% do tempo (média %.0f dB)" "$1" "$2";;
    sum_low) printf "som BAIXO (média %.0f dB)" "$1";;
    sum_ok) printf "som OK (média %.0f dB, silêncio em %d%% do tempo)" "$1" "$2";;
    no_measure) echo "sem medida";;
    no_ffmpeg) echo "SEM FFMPEG"; echo "O ffmpeg não está instalado. Rode o install.sh, ou: brew install ffmpeg";;
    no_switchaudio) echo "SEM SWITCHAUDIOSOURCE"; echo "O SwitchAudioSource não está instalado. Rode o install.sh, ou: brew install switchaudio-osx";;
    doctor_ok) echo "INSTALAÇÃO COMPLETA"; echo "Tudo de que o Ipsio precisa está no lugar.";;
    doctor_incomplete) echo "INSTALAÇÃO INCOMPLETA"; echo "Resolva os itens marcados com X e confira de novo.";;
    doctor_item) echo "OK  $1";;
    doctor_calendar_none) echo "--  agenda: nenhuma conectada (opcional; menu > Conectar agenda)";;
    doctor_calendar) echo "OK  agenda: $1";;
  esac; fi
}

# index video|audio <exact name>: the device's avfoundation index, or nothing.
# Searches only the requested section and by the whole name: by substring an
# "iPhone Microphone" would match "Microphone", and a camera the mic's name.
index() {
  ffmpeg -nostdin -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | awk -v sec="$1" -v name="$2" '
    /AVFoundation video devices/ { s = "video"; next }
    /AVFoundation audio devices/ { s = "audio"; next }
    s == sec && match($0, /\[[0-9]+\] /) {
      i = substr($0, RSTART + 1); n = i
      sub(/\].*/, "", i); sub(/^[0-9]+\] /, "", n); sub(/[ \r]+$/, "", n)
      if (n == name) { print i; exit }
    }'
}
# microphone: the name meeting mode will open. The conf one, or the system
# default input (whoever switches headsets switches the input in Settings).
microphone() { if [ -n "$MIC" ]; then printf '%s\n' "$MIC"; else SwitchAudioSource -c -t input 2>/dev/null; fi; }
# output_to_restore: where the sound goes back to. The output in use before
# start; if it is gone, or was Ipsio's own device, the first real output.
output_to_restore() {
  local o; o=$(cat "$ORIG_OUTPUT" 2>/dev/null)
  if [ -z "$o" ] || [ "$o" = "$DEVICE" ] || ! SwitchAudioSource -a -t output | grep -qxF "$o"; then
    o=$(SwitchAudioSource -a -t output | grep -vxF "$DEVICE" | grep -v '^BlackHole' | head -1)
  fi
  printf '%s\n' "$o"
}
# is_recorder <pid>: alive AND an ffmpeg. After a power cut the pid file
# survives, and its number may be reused by any other process: "alive" alone
# would refuse every start and make stop kill a stranger.
is_recorder() { kill -0 "$1" 2>/dev/null && ps -p "$1" -o args= 2>/dev/null | grep -q ffmpeg; }
recording() { [ -f "$PIDFILE" ] && is_recorder "$(cat "$PIDFILE")"; }
current_file() { cat "$FILEREC" 2>/dev/null; }
recording_mode() { cat "$MODEREC" 2>/dev/null || echo class; }
elapsed() { tr '\r' '\n' < "$LOG" 2>/dev/null | grep -oE 'time=[0-9:]+' | tail -1 | cut -d= -f2 | cut -d. -f1; }
size_of() { [ -f "$1" ] && du -h "$1" | cut -f1 | tr -d ' '; }
free_gb() { df -g "$FOLDER" 2>/dev/null | awk 'NR==2{print $4}'; }
# state <key=value...>: the machine line that ends every output the app reads.
state() { echo "#state $*"; }
# samples <meter file>: one RMS value per line (dB or -inf).
samples() { grep RMS_level "$1" 2>/dev/null | cut -d= -f2; }
last_sample() { samples "$1" | tail -1; }
# trailing_silence <file> <threshold>: consecutive seconds below it at the end.
trailing_silence() { samples "$1" | awk -v lim="$2" '{ if ($1=="-inf" || $1+0 < lim) n++; else n=0 } END{print n+0}'; }
# mic_dead <file>: true if there are samples and ALL are below the dead-mic threshold.
mic_dead() { samples "$1" | awk -v lim="$MIC_DEAD_DB" '{ n++; if (!($1=="-inf" || $1+0 < lim)) alive=1 } END{ exit !(n>0 && !alive) }'; }
# classify <average dB or -inf>: prints the key (NO_SOUND|LOW|LOUD|OK).
# Thresholds: clear speech averages between -30 and -10 dB. Decided by the
# AVERAGE, not the peak: a single click hits 0 dB with the average at -20.
classify() {
  local x="$1"
  if [ "$x" = "-inf" ] || [ -z "$x" ] || awk "BEGIN{exit !($x < $SILENCE_DB)}"; then echo NO_SOUND
  elif awk "BEGIN{exit !($x < -35)}"; then echo LOW
  elif awk "BEGIN{exit !($x > -10)}"; then echo LOUD
  else echo OK; fi
}
verdict() {
  case "$(classify "$1")" in
    NO_SOUND) t no_sound; return 2;;
    LOW) t sound_low;;
    LOUD) t sound_loud;;
    OK) t sound_ok;;
  esac; return 0
}
# sound_summary <meter file>: "CLASS SILENCE_PCT AVERAGE" of the whole
# recording, in zero seconds (one sample per second is already on disk;
# re-reading 8 h of file with volumedetect would take ~1 min with the app stuck).
# 40%: a lunch break recorded along (13% on a real day) must not become
# "gaps"; 40% of silence is already a sign of the wrong speaker.
sound_summary() {
  samples "$1" | awk -v lim="$SILENCE_DB" '
    { n++; if ($1=="-inf" || $1+0 < lim) s++; else { sum+=$1; c++ } }
    END { if (n==0) { print "NO_MEASURE 0 -99"; exit }
          pct = int(100*s/n); avg = (c>0) ? sum/c : -99
          if (pct >= 90) cl="SILENT"; else if (pct >= 40) cl="GAPS"; else if (avg < -35) cl="LOW"; else cl="OK"
          printf "%s %d %.1f\n", cl, pct, avg }'
}
# mic_summary <mic meter file>: "CLASS DEAD_PCT" (DEAD at 90% or more of the
# time; NO_MEASURE without samples).
mic_summary() {
  samples "$1" | awk -v lim="$MIC_DEAD_DB" '
    { n++; if ($1=="-inf" || $1+0 < lim) s++ }
    END { if (n==0) { print "NO_MEASURE 0"; exit }
          pct = int(100*s/n); printf "%s %d\n", (pct >= 90 ? "DEAD" : "OK"), pct }'
}
# track_mean <file> <audio track n>: volumedetect's mean_volume.
track_mean() {
  ffmpeg -nostdin -hide_banner -nostats -i "$1" -map "0:a:$2" -af volumedetect -f null - 2>&1 \
    | grep -oE 'mean_volume: *-?[0-9.inf]+' | grep -oE -- '-?([0-9.]+|inf)$'
}
# safe_path <path>: the path goes into the ffmpeg filter (file=...), where a
# space, colon, comma, quote or bracket changes its meaning.
safe_path() { case "$1" in *[\ :,\;\'\"\[\]\\]*) return 1;; esac; return 0; }
# restore_output: the system output goes back to where it was.
restore_output() { local o; o=$(output_to_restore); [ -n "$o" ] && SwitchAudioSource -t output -s "$o" >/dev/null 2>&1; }

# doctor: checks the whole setup WITHOUT recording and without stopping at the
# first problem, so a new Mac learns everything that is missing in one pass.
# Same checks as the start preflight (one source of truth: the same functions
# and the same text keys). Exits 0 only when nothing required is missing.
# Calendar is optional and never counts as missing.
doctor() {
  local miss="" out="" VID AUD MICN MICI FREE PERM cal=""
  bad() { miss="${miss:+$miss,}$1"; out="$out$(printf 'X   %s' "$(t "$2" "${3:-}" | sed -n 2p)")"$'\n'; }
  good() { out="$out$(t doctor_item "$1")"$'\n'; }
  safe_path "$DIR" || bad dir invalid_dir
  if command -v ffmpeg >/dev/null 2>&1; then
    good ffmpeg
    AUD=$(index audio "BlackHole 2ch"); VID=$(index video "Capture screen 0")
    if [ -n "$AUD" ]; then good "BlackHole 2ch"; else bad blackhole no_blackhole; fi
    if [ -n "$VID" ]; then good "Capture screen 0"; else bad screen no_screen; fi
    # Without SwitchAudioSource and with no MICROPHONE set, the input cannot be
    # known: that item is reported below, not as a fake microphone problem.
    if [ "$MODE" = "meeting" ] && { [ -n "$MIC" ] || command -v SwitchAudioSource >/dev/null 2>&1; }; then
      MICN=$(microphone); MICI=""
      case "$MICN" in
        BlackHole*|"$DEVICE") bad microphone microphone_is_blackhole "$MICN";;
        *) [ -n "$MICN" ] && MICI=$(index audio "$MICN")
           if [ -n "$MICI" ]; then good "$MICN"; else bad microphone no_microphone "$MICN"; fi;;
      esac
    fi
  else
    bad ffmpeg no_ffmpeg
  fi
  if command -v SwitchAudioSource >/dev/null 2>&1; then
    good SwitchAudioSource
    if SwitchAudioSource -a -t output | grep -qxF "$DEVICE"; then good "$DEVICE"; else bad device missing_device; fi
  else
    bad switchaudio no_switchaudio
  fi
  if mkdir -p "$FOLDER" 2>/dev/null; then
    good "$FOLDER"
    FREE=$(free_gb)
    if [ -n "$FREE" ] && [ "$FREE" -lt "$MIN_GB" ]; then bad disk disk_full "$FREE"; else good "${FREE:-?} GB"; fi
  else
    bad folder folder_inaccessible
  fi
  PERM="${TMPDIR:-/tmp}/ipsio-perm-$$.png"; rm -f "$PERM"
  screencapture -x -t png "$PERM" 2>/dev/null
  if [ -s "$PERM" ]; then good "screen permission"; else bad permission no_permission; fi
  rm -f "$PERM"
  [ -s "$DIR/calendar.url" ] && cal="${cal:+$cal,}ics"
  [ -s "$DIR/calendar.txt" ] && cal="${cal:+$cal,}list"
  [ -n "${CALENDAR_COMMAND:-}" ] && cal="${cal:+$cal,}command"
  if [ -n "$miss" ]; then t doctor_incomplete; else t doctor_ok; fi
  echo
  printf '%s' "$out"
  if [ -n "$cal" ]; then t doctor_calendar "$cal"; else t doctor_calendar_none; fi
  if [ -n "$miss" ]; then state verdict=SETUP_INCOMPLETE mode="$MODE" missing="$miss" calendar="${cal:-none}"; return 1; fi
  state verdict=SETUP_OK mode="$MODE" missing= calendar="${cal:-none}"
}

main() {
case "$1" in
  start)
    if recording; then t already_recording; state verdict=ALREADY_RECORDING; exit 0; fi
    mkdir -p "$DIR"
    safe_path "$DIR" || { t invalid_dir; state verdict=INVALID_DIR; exit 1; }
    # --- preflight, fail closed: every item below REFUSES with a verdict ---
    VID=$(index video "Capture screen 0"); AUD=$(index audio "BlackHole 2ch")
    [ -z "$AUD" ] && { t no_blackhole; state verdict=NO_BLACKHOLE; exit 1; }
    [ -z "$VID" ] && { t no_screen; state verdict=NO_SCREEN; exit 1; }
    # Microphone only in meeting mode: a class is listening, a meeting needs
    # YOUR voice, which does not go through BlackHole. Asked for and absent REFUSES.
    MICN=""; MICI=""
    if [ "$MODE" = "meeting" ]; then
      MICN=$(microphone)
      case "$MICN" in BlackHole*|"$DEVICE") t microphone_is_blackhole "$MICN"; state verdict=MICROPHONE_IS_BLACKHOLE; exit 1;; esac
      [ -n "$MICN" ] && MICI=$(index audio "$MICN")
      [ -z "$MICI" ] && { t no_microphone "$MICN"; state verdict=NO_MICROPHONE; exit 1; }
    fi
    SwitchAudioSource -a -t output | grep -qxF "$DEVICE" || { t missing_device; state verdict=MISSING_DEVICE; exit 1; }
    mkdir -p "$FOLDER" || { t folder_inaccessible; state verdict=FOLDER_INACCESSIBLE; exit 1; }
    FREE=$(free_gb)
    if [ -n "$FREE" ] && [ "$FREE" -lt "$MIN_GB" ]; then t disk_full "$FREE"; state verdict=DISK_FULL free_gb="$FREE"; exit 1; fi
    PERM="${TMPDIR:-/tmp}/ipsio-perm-$$.png"; rm -f "$PERM"
    screencapture -x -t png "$PERM" 2>/dev/null
    [ -s "$PERM" ] || { t no_permission; state verdict=NO_PERMISSION; exit 1; }
    rm -f "$PERM"
    WARN=""
    pmset -g batt 2>/dev/null | grep -q "Battery Power" && WARN=$(t battery_warning)
    # --- launch ---
    BASE="$FOLDER/$(date +%Y-%m-%d_%H-%M)${TITLE:+ $TITLE}"; OUT="$BASE.mkv"; n=2
    while [ -e "$OUT" ]; do OUT="$BASE ($n).mkv"; n=$((n+1)); done
    SwitchAudioSource -c -t output > "$ORIG_OUTPUT"
    SwitchAudioSource -t output -s "$DEVICE" >/dev/null 2>&1
    rm -f "$LEVEL" "$LEVEL_MIC"
    METER="asetnsamples=n=48000,astats=metadata=1:reset=10,ametadata=print:key=lavfi.astats.Overall.RMS_level:direct=1:file="
    if [ "$MODE" = "meeting" ]; then
      # Meeting: track 1 = mix (computer + microphone), 2 = computer only (the
      # others), 3 = microphone only (you).
      # Separate tracks let a transcription know who spoke. aresample async
      # absorbs the drift between the two clocks (BlackHole and the microphone
      # are different devices). The microphone has its own meter: that is what
      # flags a dead microphone while the computer sound is fine. The main
      # meter reads the COMPUTER branch, never the mix: on the mix, your own
      # voice (or room noise) would hide a silent BlackHole, which is exactly
      # the failure this meter exists to catch.
      nohup ffmpeg -nostdin -y -f avfoundation -capture_cursor 1 -framerate 12 -i "$VID:$AUD" \
        -f avfoundation -i ":$MICI" \
        -filter_complex "[0:a]aresample=48000:async=1000,aformat=channel_layouts=stereo,asplit=3[s1][s2][s3];[1:a]aresample=48000:async=1000,aformat=channel_layouts=stereo,asplit=3[m1][m2][m3];[s1][m1]amix=inputs=2:duration=first:normalize=0[mix];[s3]${METER}${LEVEL}[meto];[m3]${METER}${LEVEL_MIC}[mico]" \
        -map 0:v -map "[mix]" -map "[s2]" -map "[m2]" -c:v h264_videotoolbox -b:v 4M -pix_fmt yuv420p -c:a aac -b:a 128k "$OUT" \
        -map "[meto]" -f null - -map "[mico]" -f null - \
        > "$LOG" 2>&1 &
    else
      nohup ffmpeg -nostdin -y -f avfoundation -capture_cursor 1 -framerate 12 -i "$VID:$AUD" \
        -map 0:v -map 0:a -c:v h264_videotoolbox -b:v 4M -pix_fmt yuv420p -c:a aac -b:a 128k "$OUT" \
        -map 0:a -af "${METER}${LEVEL}" -f null - \
        > "$LOG" 2>&1 &
    fi
    PID=$!
    echo "$PID" > "$PIDFILE"
    echo "$OUT" > "$FILEREC"
    echo "$MODE" > "$MODEREC"
    nohup caffeinate -dimsu -w "$PID" >/dev/null 2>&1 &
    sleep 2
    if ! kill -0 "$PID" 2>/dev/null; then
      rm -f "$PIDFILE"; restore_output
      t did_not_start; tail -c 400 "$LOG"; state verdict=DID_NOT_START; exit 1; fi
    MICOK=1
    if [ "$MODE" = "meeting" ]; then
      # Up to 4 s for the first microphone sample. Dead does NOT stop the
      # recording: the others are coming in, and in a meeting with nobody at
      # the Mac, losing everything because of the microphone is worse than
      # recording without it. But the verdict says so, and the app turns yellow.
      for _ in 1 2 3 4; do [ -n "$(last_sample "$LEVEL_MIC")" ] && break; sleep 1; done
      # No sample at all in 4 s also counts as dead: a silent meter is no proof
      # of a live microphone (fail closed).
      if [ -z "$(last_sample "$LEVEL_MIC")" ] || mic_dead "$LEVEL_MIC"; then MICOK=0; fi
    fi
    if [ "$MICOK" = 0 ]; then t microphone_dead_start "$(basename "$OUT")" "$MICN"
    elif [ "$MODE" = "meeting" ]; then t recording_meeting "$(basename "$OUT")" "$MICN"
    else t recording "$(basename "$OUT")"; fi
    [ -n "$WARN" ] && echo "$WARN"
    echo ""
    t detail "$(t detail_start "$PID" "$(SwitchAudioSource -c -t output)" "${FREE:-?}" "$MODE")"
    state verdict=RECORDING mode="$MODE" microphone=$([ "$MICOK" = 0 ] && echo DEAD || echo OK) battery=$([ -n "$WARN" ] && echo 1 || echo 0) file="$OUT"
    ;;
  level)
    # Reads the LAST sample of the live meter. Cheap: one grep.
    recording || { t not_recording; state verdict=NOT_RECORDING; exit 1; }
    LAST=$(last_sample "$LEVEL")
    T=$(elapsed); SZ=$(size_of "$(current_file)"); FREE=$(free_gb); HOURS=$(( ${FREE:-0} * 10 / 18 ))
    RM=$(recording_mode); MICS=""; MS=0
    if [ "$RM" = "meeting" ]; then
      MS=$(trailing_silence "$LEVEL_MIC" "$MIC_DEAD_DB")
      # Microphone meter silent while the computer one writes: counts as dead
      # since the start, not as "no measurement" (fail closed).
      [ -z "$(last_sample "$LEVEL_MIC")" ] && MS=$(samples "$LEVEL" | wc -l | tr -d ' ')
      MICS=" mic=$(last_sample "$LEVEL_MIC") mic_silence=$MS"
    fi
    if [ -z "$LAST" ]; then t measuring; echo ""; t detail "$(t recorded "$T" "$SZ")"; state "verdict=MEASURING mode=$RM silence=0 time=$T size=$SZ disk_h=$HOURS$MICS"; exit 0; fi
    # astats writes ONE sample per second, each over the window of the last
    # 10 s (reset=10 is the window, not the step; measured: 57 samples in
    # 64 s). Consecutive samples below -60 dB at the end = seconds of silence.
    SIL=$(trailing_silence "$LEVEL" "$SILENCE_DB")
    verdict "$LAST"; RC=$?
    [ "$SIL" -gt 0 ] && t silent_for "$SIL"
    [ "$RM" = "meeting" ] && [ "$MS" -gt 0 ] && t microphone_dead "$MS"
    echo ""
    t detail "$(t detail_level "$LAST" "$T" "$SZ" "${FREE:-?}" "$HOURS")"
    [ "$RM" = "meeting" ] && t detail "$(t detail_mic "$(last_sample "$LEVEL_MIC")")"
    state "verdict=$(classify "$LAST") mode=$RM silence=$SIL time=$T size=$SZ disk_h=$HOURS$MICS"
    exit $RC
    ;;
  check)
    # volumedetect prints at INFO level: with -v error NOTHING comes out.
    A=$(current_file)
    [ -f "$A" ] || { t not_recording; state verdict=NOT_RECORDING; exit 1; }
    ffprobe -v error -select_streams a -show_entries stream=codec_name -of default=noprint_wrappers=1 "$A" | grep -q codec_name || { t no_track; state verdict=NO_SOUND; exit 2; }
    # In a meeting, track 0 is the mix: measure track 1 (computer only), or
    # your voice passes for the others' sound.
    TR=0; [ "$(recording_mode)" = "meeting" ] && TR=1
    VD=$(ffmpeg -nostdin -hide_banner -nostats -i "$A" -map "0:a:$TR" -af volumedetect -f null - 2>&1)
    MEAN=$(echo "$VD" | grep -oE 'mean_volume: *-?[0-9.]+' | grep -oE -- '-?[0-9.]+$')
    MAX=$(echo "$VD" | grep -oE 'max_volume: *-?[0-9.]+' | grep -oE -- '-?[0-9.]+$')
    [ -n "$MEAN" ] || { t too_early; state verdict=TOO_EARLY; exit 1; }
    verdict "$MEAN"; RC=$?
    echo ""
    t detail "$(t detail_check "$MEAN" "$MAX" "$(elapsed)" "$(size_of "$A")")"
    state verdict="$(classify "$MEAN")" mean="$MEAN" peak="$MAX"
    exit $RC
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      # The pid file goes away BEFORE the kill: the app's watchdog reads "pid
      # file present with a dead process" as a crash, and between ffmpeg ending
      # and the rm there was up to 1 s of window (a normal stop once popped
      # "THE RECORDING STOPPED BY ITSELF" and offered to record again).
      P=$(cat "$PIDFILE"); rm -f "$PIDFILE"
      if is_recorder "$P"; then
        kill -INT "$P" 2>/dev/null   # SIGINT: ffmpeg closes the file cleanly
        for _ in 1 2 3 4 5; do is_recorder "$P" || break; sleep 1; done
        is_recorder "$P" && kill -9 "$P" 2>/dev/null   # only if still alive; the mkv survives
      fi
    fi
    restore_output
    A=$(current_file)
    if [ -n "$A" ] && [ -f "$A" ]; then
      D=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$A" 2>/dev/null)
      DUR=$(echo "${D:-0}" | awk '{h=int($1/3600); mi=int(($1%3600)/60); if(h>0) printf "%dh%02dmin", h, mi; else if (mi>0) printf "%d min", mi; else printf "%d s", int($1)}')
      read -r CLASS PCT AVG <<< "$(sound_summary "$LEVEL")"
      case "$CLASS" in
        SILENT) SND=$(t sum_silent "$PCT"); TIT=saved_silent;;
        GAPS) SND=$(t sum_gaps "$((100-PCT))" "$AVG"); TIT=saved_gaps;;
        LOW) SND=$(t sum_low "$AVG"); TIT=saved;;
        OK) SND=$(t sum_ok "$AVG" "$PCT"); TIT=saved;;
        *) SND=$(t no_measure); TIT=saved;;
      esac
      MICCL=""
      if [ "$(recording_mode)" = "meeting" ]; then
        read -r MICCL MICPCT <<< "$(mic_summary "$LEVEL_MIC")"
        case "$MICCL" in
          DEAD) SND="$SND, $(t mic_sum_dead "$MICPCT")"; [ "$TIT" = saved ] && TIT=saved_mic_dead;;
          OK) SND="$SND, $(t mic_sum_ok)";;
        esac
      fi
      if [ -z "$D" ] || awk "BEGIN{exit !(${D:-0} <= 0)}"; then
        t does_not_open "$(basename "$A")" "$(size_of "$A")"; echo ""; t detail "$(t detail_stop "$(SwitchAudioSource -c -t output)")"; state verdict=DOES_NOT_OPEN file="$A"; exit 1
      fi
      t "$TIT"
      t saved_body "$(basename "$A")" "$DUR" "$(size_of "$A")" "$SND" "$(dirname "$A")"
      echo ""
      t detail "$(t detail_stop "$(SwitchAudioSource -c -t output)")"
      state "verdict=SAVED sound=$CLASS silence_pct=$PCT mean=$AVG${MICCL:+ microphone=$MICCL} duration=$DUR file=$A"
    else
      t was_not_recording; state verdict=NOT_RECORDING
    fi
    ;;
  status)
    if recording; then
      A=$(current_file)
      echo "RECORDING (pid $(cat "$PIDFILE"), $(recording_mode)) -> $A"
      [ -f "$A" ] && t recorded "$(elapsed)" "$(size_of "$A")"
      bash "$0" level | head -1
    else t stopped; fi
    ;;
  test)
    # A dress rehearsal in one click: records 10 s with a sentence spoken by
    # the Mac, measures the file, stops, deletes it and gives the verdict. It
    # only proves the Mac -> BlackHole path (and, in meeting mode, the
    # microphone); the speaker inside Zoom/Teams is proven live, on the day.
    if recording; then t already_recording; state verdict=ALREADY_RECORDING; exit 1; fi
    S=$(IPSIO_TITLE=test bash "$0" start); RC=$?
    if [ $RC -ne 0 ]; then echo "$S"; exit $RC; fi
    MICN=$(microphone)
    sleep 2
    # The Mac's default voice follows the system language, and an American
    # voice reading Portuguese is unintelligible: in pt use Luciana (pt_BR).
    if [ "$L" = "pt" ] && say -v '?' 2>/dev/null | grep -q '^Luciana '; then say -v Luciana "teste de gravação: um, dois, três, quatro, cinco" 2>/dev/null
    else say "recording test: one, two, three, four, five" 2>/dev/null; fi
    sleep 3
    A=$(current_file)
    bash "$0" stop >/dev/null
    # Meeting: the sentence must reach the COMPUTER track (1), not just the
    # mix; the microphone hears the speaker and would pass a broken BlackHole.
    if [ "$MODE" = "meeting" ]; then MEAN=$(track_mean "$A" 1); MICM=$(track_mean "$A" 2)
    else MEAN=$(track_mean "$A" 0); MICM=""; fi
    HAS_VIDEO=$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$A" 2>/dev/null)
    rm -f "$A" "$FILEREC"
    [ -z "$HAS_VIDEO" ] && { t test_no_video; state verdict=TEST_NO_VIDEO; exit 1; }
    if [ -z "$MEAN" ] || [ "$(classify "$MEAN")" = "NO_SOUND" ]; then t test_no_sound; state verdict=TEST_NO_SOUND; exit 2; fi
    if [ "$MODE" = "meeting" ]; then
      if [ -z "$MICM" ] || [ "$MICM" = "-inf" ] || awk "BEGIN{exit !($MICM < $MIC_DEAD_DB)}"; then
        t test_no_microphone "$MICN"; state verdict=TEST_NO_MICROPHONE mean="$MEAN" mic="${MICM:-}"; exit 2; fi
      t test_ok_meeting "$MICN"
      echo ""; t detail "$(t detail_test_mic "$MEAN" "$MICM")"
      state verdict=TEST_OK mode=meeting mean="$MEAN" mic="$MICM"
    else
      t test_ok
      echo ""; t detail "$(t detail_test "$MEAN")"
      state verdict=TEST_OK mode=class mean="$MEAN"
    fi
    ;;
  folder) echo "$FOLDER";;
  title) echo "$TITLE";;
  output) SwitchAudioSource -c -t output;;
  device) echo "$DEVICE";;
  language) echo "$L";;
  mode) echo "$MODE";;
  microphone) microphone;;
  doctor) doctor; exit $?;;
  *) echo "usage: ipsio.sh start|level|check|status|stop|test|doctor|folder|title|output|device|language|mode|microphone";;
esac
}

# IPSIO_ONLY_FUNCTIONS=1 loads the functions without running anything (that is
# how the tests exercise preflight and summaries with no Mac, no ffmpeg and no
# BlackHole).
[ -n "${IPSIO_ONLY_FUNCTIONS:-}" ] || main "$@"
