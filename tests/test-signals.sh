#!/bin/bash
# test-signals.sh: bench for the signal to the office panel (ipsio.sh, section
# "signal to a panel"). No network: curl is a double that answers the HTTP
# codes listed in $STUB/codes (one per call, 200 when the list runs out) and
# keeps every body it was handed. Runs on Linux and macOS. Exits 1 on any
# failed assertion. IPSIO_SCRIPT points it at another copy of ipsio.sh (that
# is how tests/signal-mutants.sh plants defects).
#
# What it proves, and why each item exists:
# - a saved recording becomes reuniao_gravada (1) and minutos_gravados;
# - the file name, the title and a lawsuit number in the name NEVER leave, and
#   the ref is the recording's SHA-256 in groups of 8 (plain hex has a run of 11
#   or 14 digits in 5.5% of hashes, which the panel refuses as a CPF/CNPJ);
# - caso_hash only with a salt, and it is sha256(salt + the 20 digits);
# - 503 and no network keep the signal queued; the next drain sends it, with
#   the same idempotencia (the panel keeps one); 400 drops it;
# - queueing the same recording twice keeps one line per measure;
# - PROJETOS_SINAL_DESLIGADO=1 neither queues nor sends; without URL or secret
#   it queues and sends nothing;
# - a field that looks like a CPF/CNPJ is refused before it is queued;
# - the secret never reaches curl's command line, the log or the queue.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${IPSIO_SCRIPT:-$HERE/../ipsio.sh}"
FAILS=0; TOTAL=0
ok() { TOTAL=$((TOTAL+1)); echo "ok   $1"; }
fail() { TOTAL=$((TOTAL+1)); FAILS=$((FAILS+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
has() { case "$2" in *"$3"*) ok "$1";; *) fail "$1" "expected '$3' in: $(printf '%s' "$2" | tr '\n' '|')";; esac; }
lacks() { case "$2" in *"$3"*) fail "$1" "did not expect '$3' in: $(printf '%s' "$2" | tr '\n' '|')";; *) ok "$1";; esac; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$3], got [$2]"; fi; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ipsio-signals.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
STUB="$ROOT/stub"; BIN="$ROOT/bin"; mkdir -p "$STUB" "$BIN"
# curl double: config from stdin (-K -) to curl-config, arguments to curl-args,
# the body (--data-binary @file) appended to bodies; answers the next code.
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
cat >> "$STUB/curl-config"
printf '%s\n' "$*" >> "$STUB/curl-args"
prev=""; for a in "$@"; do [ "$prev" = "--data-binary" ] && { cat "${a#@}"; echo; } >> "$STUB/bodies"; prev="$a"; done
code=200
if [ -s "$STUB/codes" ]; then code=$(head -1 "$STUB/codes"); tail -n +2 "$STUB/codes" > "$STUB/codes.t"; mv "$STUB/codes.t" "$STUB/codes"; fi
[ "$code" = 000 ] && { printf '000'; exit 7; }
printf '%s' "$code"
EOF
chmod +x "$BIN/curl"

SECRET='FAKE-SECRET-for-the-bench-zqv'
MARK='Zqxwv Meeting'                       # a title that must never leave
CNJ='0001234-56.2024.8.19.0001'            # a lawsuit number in the name
NAME="2026-10-11_10-00 $MARK $CNJ.mkv"
# A hash whose hex has a run of 11 digits: the panel would refuse it as a CPF.
SHA='a12345678901bcdef0123456789abcdef0123456789abcdef0123456789abcd'
SHA="${SHA}e"

reset() { rm -rf "${ROOT:?}/home" "${STUB:?}"/*; mkdir -p "$ROOT/home/.ipsio"; : > "$ROOT/home/.ipsio/conf"; }
# fn <shell code> [VAR=value...]: the script's functions, with a bench HOME and PATH.
fn() {
  local code="$1"; shift
  env -i HOME="$ROOT/home" PATH="$BIN:/usr/bin:/bin" STUB="$STUB" TMPDIR="$ROOT" IPSIO_ONLY_FUNCTIONS=1 "$@" \
    bash -c ". \"\$0\"; $code" "$SCRIPT" 2>&1
}
CFG=(PROJETOS_SINAL_URL=http://panel.invalid PROJETOS_SINAL_SECRET="$SECRET")
record() { fn "signal_recording \"$ROOT/rec/$NAME\" $SHA 750 meeting" "$@"; }
Q="$ROOT/home/.ipsio/signals.jsonl"; LOGF="$ROOT/home/.ipsio/signals.log"
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
grouped() { printf '%s' "$1" | sed -E 's/(.{8})/\1:/g; s/:$//'; }
sha_str() { printf '%s' "$1" | openssl dgst -sha256 -r | awk '{print $1}'; }

# ----------------------------------------------------- the happy path ---
reset; record "${CFG[@]}" >/dev/null
B=$(cat "$STUB/bodies" 2>/dev/null)
same "two measures are sent for one recording" "$(lines "$STUB/bodies")" "2"
has "reuniao_gravada with value 1" "$B" '"metrica":"reuniao_gravada","valor":1,'
has "minutos_gravados from the duration (750 s = 12.5 min)" "$B" '"metrica":"minutos_gravados","valor":12.5,'
has "tipo operacao, projeto ipsio" "$B" '{"projeto":"ipsio","tipo":"operacao",'
has "a meeting is alvo reuniao" "$B" '"alvo":"reuniao"'
REF=$(grouped "$SHA")
has "the ref is the recording's sha256 in groups of 8" "$B" "\"ref\":\"$REF\""
has "idempotencia is project, metric and sha" "$B" "\"idempotencia\":\"ipsio:minutos_gravados:$SHA\""
lacks "the ref is never plain hex" "$B" "\"ref\":\"$SHA\""
lacks "the title never leaves" "$B" "Zqxwv"
lacks "the file name never leaves" "$B" ".mkv"
lacks "the lawsuit number never leaves (masked)" "$B" "$CNJ"
lacks "the lawsuit number never leaves (digits)" "$B" "00012345620248190001"
printf '%s\n' "$B" | grep -qE '"ocorrido_em":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}"' \
  && ok "ocorrido_em is ISO 8601 with its offset" || fail "ocorrido_em is ISO 8601 with its offset" "$B"
same "a sent signal leaves the queue" "$(lines "$Q")" "0"
has "the send is logged" "$(cat "$LOGF")" "sent minutos_gravados"
has "the url gets /projetos/sinal" "$(cat "$STUB/curl-args")" "http://panel.invalid/projetos/sinal"
lacks "the secret is not on curl's command line" "$(cat "$STUB/curl-args")" "$SECRET"
has "the secret goes in the header, on stdin" "$(cat "$STUB/curl-config")" "header = \"X-Projetos-Secret: $SECRET\""
lacks "the secret is not in the log" "$(cat "$LOGF")" "$SECRET"
lacks "the title is not in the log" "$(cat "$LOGF")" "Zqxwv"
lacks "no caso_hash without a salt" "$B" "caso_hash"
has "the missing salt is logged" "$(cat "$LOGF")" "PROJETOS_SINAL_SAL is not set"

# --------------------------------------------------------- case link ---
reset; record "${CFG[@]}" PROJETOS_SINAL_SAL=pepper-zz >/dev/null
B=$(cat "$STUB/bodies" 2>/dev/null)
has "with a salt, caso_hash = sha256(salt + the 20 digits), grouped" "$B" "\"caso_hash\":\"$(grouped "$(sha_str "pepper-zz00012345620248190001")")\""
lacks "with a salt, the lawsuit number still never leaves" "$B" "00012345620248190001"
reset; fn "signal_recording \"$ROOT/rec/2026-10-11_10-00 Class.mkv\" $SHA 60 class" "${CFG[@]}" PROJETOS_SINAL_SAL=pepper-zz >/dev/null
B=$(cat "$STUB/bodies" 2>/dev/null)
lacks "no lawsuit number in the name, no caso_hash" "$B" "caso_hash"
has "a class is alvo aula" "$B" '"alvo":"aula"'

# ------------------------------------------------- queue and resend ---
reset; echo 503 > "$STUB/codes"; record "${CFG[@]}" >/dev/null
same "503 keeps both signals queued" "$(lines "$Q")" "2"
same "a panel that is down is tried once per drain, not once per line" "$(lines "$STUB/curl-args")" "1"
has "the kept signals are logged with the code" "$(cat "$LOGF")" "kept 2: http 503 on reuniao_gravada"
K1=$(grep -o '"idempotencia":"[^"]*"' "$STUB/bodies" | sort)
: > "$STUB/bodies"
S=$(env -i HOME="$ROOT/home" PATH="$BIN:/usr/bin:/bin" STUB="$STUB" TMPDIR="$ROOT" "${CFG[@]}" bash "$SCRIPT" signals 2>&1)
has "ipsio signals drains the queue" "$S" "#state signals_pending=0"
same "the queue is empty after the drain" "$(lines "$Q")" "0"
has "the resend carries the same idempotencia (the panel keeps one)" "$(cat "$STUB/bodies")" "$K1"
same "the drain sends both kept signals" "$(lines "$STUB/bodies")" "2"

reset; echo 000 > "$STUB/codes"; record "${CFG[@]}" >/dev/null
same "no network keeps both signals queued" "$(lines "$Q")" "2"
reset; echo 403 > "$STUB/codes"; record "${CFG[@]}" >/dev/null
same "403 (secret refused) keeps the signals queued" "$(lines "$Q")" "2"
reset; echo 409 > "$STUB/codes"; record "${CFG[@]}" >/dev/null
same "409 (not the production panel) keeps the signals queued" "$(lines "$Q")" "2"
reset; printf '400\n200\n' > "$STUB/codes"; record "${CFG[@]}" >/dev/null
same "400 drops the refused signal" "$(lines "$Q")" "0"
has "the drop is logged" "$(cat "$LOGF")" "dropped reuniao_gravada: refused by the panel (400)"

reset; record >/dev/null; record >/dev/null
same "the same recording queued twice keeps one line per measure" "$(lines "$Q")" "2"
[ -e "$STUB/curl-args" ] && fail "without URL and secret nothing is sent" || ok "without URL and secret nothing is sent"
has "without URL and secret the log says why" "$(cat "$LOGF")" "PROJETOS_SINAL_URL or PROJETOS_SINAL_SECRET not set"
lacks "the queue never holds the title" "$(cat "$Q")" "Zqxwv"
lacks "the queue never holds the secret" "$(cat "$Q")" "$SECRET"

# --------------------------------------------------------- kill switch ---
reset; record "${CFG[@]}" PROJETOS_SINAL_DESLIGADO=1 >/dev/null
[ -e "$Q" ] && fail "the kill switch queues nothing" || ok "the kill switch queues nothing"
[ -e "$STUB/curl-args" ] && fail "the kill switch sends nothing" || ok "the kill switch sends nothing"
has "the kill switch is logged" "$(cat "$LOGF")" "PROJETOS_SINAL_DESLIGADO=1"
reset; record >/dev/null
S=$(env -i HOME="$ROOT/home" PATH="$BIN:/usr/bin:/bin" STUB="$STUB" TMPDIR="$ROOT" "${CFG[@]}" PROJETOS_SINAL_DESLIGADO=1 bash "$SCRIPT" signals 2>&1)
[ -e "$STUB/curl-args" ] && fail "the kill switch stops the drain too" || ok "the kill switch stops the drain too"
has "the kill switch keeps what was queued" "$S" "pending 2"

# ------------------------------------------------- the PII gate itself ---
fn 'looks_like_document "a12345678901b"' >/dev/null && ok "11 digits in a row look like a CPF" || fail "11 digits in a row look like a CPF"
fn 'looks_like_document "x 123.456.789-01 y"' >/dev/null && ok "a masked CPF looks like one" || fail "a masked CPF looks like one"
fn 'looks_like_document "12.345.678/0001-90"' >/dev/null && ok "a masked CNPJ looks like one" || fail "a masked CNPJ looks like one"
fn "looks_like_document \"$(grouped "$SHA")\"" >/dev/null && fail "the grouped sha does not look like a document" || ok "the grouped sha does not look like a document"
fn 'looks_like_document "{\"modo\":\"meeting\"}"' >/dev/null && fail "plain meta does not look like a document" || ok "plain meta does not look like a document"
reset; fn "signal_enqueue $SHA reuniao_gravada 1 '123.456.789-01' '{}' x.mkv" "${CFG[@]}" >/dev/null
[ -e "$Q" ] && fail "a CPF in alvo is refused before the queue" || ok "a CPF in alvo is refused before the queue"
has "the refusal names the rule, not the value" "$(cat "$LOGF")" "refused reuniao_gravada: pii_alvo"
lacks "the refusal does not log the value" "$(cat "$LOGF")" "123.456.789"
reset; fn "signal_enqueue $SHA reuniao_gravada 1 reuniao '{\"x\":\"rec Zqxwv.mkv\"}' 'rec Zqxwv.mkv'" "${CFG[@]}" >/dev/null
[ -e "$Q" ] && fail "a line holding the file name is refused" || ok "a line holding the file name is refused"
has "that refusal is logged" "$(cat "$LOGF")" "file name in the signal"

echo
echo "$((TOTAL-FAILS))/$TOTAL ok"
[ "$FAILS" -eq 0 ]
