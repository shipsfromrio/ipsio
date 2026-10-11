#!/bin/bash
# signal-mutants.sh: proves tests/test-signals.sh FAILS a broken signal. For
# each planted defect (one at a time, on a copy of ipsio.sh), the bench must
# fail. A bench that passes with the defect is blind. Runs on Linux and macOS
# (python3 only does the text replacement). Exits 1 if any mutant survives.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/ipsio-signal-mutants.XXXXXX"); trap 'rm -rf "$T"' EXIT
ALIVE=0
mutant() { # <name> <original text> <broken text>
  python3 - "$ROOT/ipsio.sh" "$T/ipsio.sh" "$2" "$3" <<'PY' || { echo "ERROR: the snippet for mutant '$1' is no longer in ipsio.sh"; ALIVE=$((ALIVE+1)); return; }
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if a not in s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
  if IPSIO_SCRIPT="$T/ipsio.sh" bash "$HERE/test-signals.sh" >/dev/null 2>&1; then echo "SURVIVED: $1"; ALIVE=$((ALIVE+1)); else echo "killed: $1"; fi
}
mutant "ref in plain hex" 'ref=$(grouped "$1")' 'ref=$1'
mutant "file name guard off" 'case "$line" in *"$6"*)' 'case "$line" in *"$6-never"*)'
mutant "PII gate off" 'END { exit !found }' 'END { exit 1 }'
mutant "503 drops the signal" "*) printf '%s\\n' \"\$line\" >> \"\$rest\"; cat >> \"\$rest\"" '*) cat >> "$rest"'
mutant "a down panel is tried for every line" ' cat >> "$rest"' ' :'
mutant "400 kept forever" '400) signal_log' '499) signal_log'
mutant "no dedupe on the queue" 'grep -qF "\"idempotencia\":\"$key\"" "$SIGNAL_Q"' 'false'
mutant "idempotencia without the metric" 'key="ipsio:$2:$1"' 'key="ipsio:$1"'
mutant "kill switch ignored when queueing" 'if [ "${PROJETOS_SINAL_DESLIGADO:-}" = 1 ]; then signal_log "off (PROJETOS_SINAL_DESLIGADO=1): nothing queued"' 'if false; then signal_log "off (PROJETOS_SINAL_DESLIGADO=1): nothing queued"'
mutant "kill switch ignored when sending" 'if [ "${PROJETOS_SINAL_DESLIGADO:-}" = 1 ]; then signal_log "off (PROJETOS_SINAL_DESLIGADO=1): nothing sent"' 'if false; then signal_log "off (PROJETOS_SINAL_DESLIGADO=1): nothing sent"'
mutant "secret on curl's command line" "curl -s -K - -o /dev/null" "curl -s -K - -H \"X-Projetos-Secret: \$PROJETOS_SINAL_SECRET\" -o /dev/null"
mutant "caso_hash without a salt" 'if [ -n "${PROJETOS_SINAL_SAL:-}" ]; then' 'if true; then'
mutant "caso_hash unsalted" "printf '%s%s' \"\$PROJETOS_SINAL_SAL\" \"\$cnj\"" "printf '%s' \"\$cnj\""
mutant "minutes in seconds" 'printf "%.1f", d / 60' 'printf "%.1f", d'
echo
if [ "$ALIVE" -eq 0 ]; then echo "every signal mutant was killed"; else echo "$ALIVE mutant(s) survived or broke"; fi
[ "$ALIVE" -eq 0 ]
