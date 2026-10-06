#!/bin/bash
# mutants.sh: proves the calendar bench FAILS a broken calendar. For each
# planted defect (one at a time, on a copy), it compiles the bench against the
# copy and requires it to fail. A bench that passes with the defect is blind.
# macOS only (needs swiftc). Exits 1 if any mutant survives.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/ipsio-mutants.XXXXXX"); trap 'rm -rf "$T"' EXIT
ALIVE=0
mutant() { # <name> <original text> <broken text>
  python3 - "$ROOT/app/Schedule.swift" "$T/Schedule.swift" "$2" "$3" <<'PY' || { echo "ERROR: the snippet for mutant '$1' is no longer in Schedule.swift"; ALIVE=$((ALIVE+1)); return; }
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if a not in s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
  if ! swiftc -parse-as-library "$T/Schedule.swift" "$ROOT/tests/ScheduleTests.swift" -o "$T/t" 2>"$T/err"; then
    echo "ERROR: mutant '$1' does not compile"; tail -3 "$T/err"; ALIVE=$((ALIVE+1)); return; fi
  if "$T/t" >/dev/null 2>&1; then echo "SURVIVED: $1"; ALIVE=$((ALIVE+1)); else echo "killed: $1"; fi
}
mutant "EXDATE ignored" 'if b.exDates.contains(d) { continue }' ''
mutant "RECURRENCE-ID ignored" 'moved[b.uid + "@" + key(b.recId!)] = b' '_ = b'
mutant "cancelled kept" 'b.status != "CANCELLED"' 'true'
mutant "decline matched by suffix" 'who == meLower,' 'who.hasSuffix(meLower),'
mutant "decline ignored" 'cur!.declined = true' 'cur!.declined = false'
mutant "folded line not unfolded" 'out[out.count - 1] += String(l.dropFirst())' 'out.append(l)'
mutant "VALARM counts" 'guard cur != nil, depth == 0 else { continue }' 'guard cur != nil else { continue }'
mutant "all-day kept" '!b.declined, !b.allDay' '!b.declined'
mutant "time zone ignored" 'if let t = tzid, let z = TimeZone(identifier: t) { cur!.tz = z }' ''
mutant "COUNT after EXDATE" 'emitted += 1' 'emitted += 0'
mutant "back-to-back does not switch" 'a.start != b.start ? a.start < b.start' 'a.start != b.start ? a.start > b.start'
mutant "after margin ignored" 'now < $0.end.addingTimeInterval(after)' 'now < $0.end'
mutant "failed source vanishes" 'let old = cache.filter { !sourcesOk.contains($0.source) }' 'let old: [Meeting] = []'
mutant "no link kept" 'if linkOnly && l.isEmpty { return }' ''
mutant "missing file reads as empty" 'return .failure(Failure(description: Schedule.L("could not read ", "não consegui ler ") + url.path))' 'return .success("")'
mutant "connect saves a non-calendar" 'guard text.contains("BEGIN:VCALENDAR") else {
            return .failure(Failure(description: Schedule.L("the address did not answer with a calendar"' 'guard true else {
            return .failure(Failure(description: Schedule.L("the address did not answer with a calendar"'
mutant "connect saves world-readable" 'O_WRONLY | O_CREAT | O_EXCL, 0o600)' 'O_WRONLY | O_CREAT | O_EXCL, 0o644)'
mutant "connect accepts plain http" 'guard u.lowercased().hasPrefix("https://"),' 'guard u.lowercased().hasPrefix("http"),'
mutant "stale clock never fires" 'return now.timeIntervalSince(lastOk ?? start) > limit' 'return now.timeIntervalSince(lastOk ?? start) > limit * 100'
mutant "stale clock ignores the last success" 'return now.timeIntervalSince(lastOk ?? start) > limit' 'return now.timeIntervalSince(start) > limit'
mutant "the meeting recording is cut by an overlap" 'if now < cur.end { return cur }' ''
mutant "a covered invite starts after the call" '$0.id != c && $0.end > cur.end' '$0.id != c'
mutant "a removed calendar records from the cache" '.filter { c.contains($0.source) }' ''
mutant "the runner ignores its deadline" 'g.wait(timeout: .now() + limit)' 'g.wait(timeout: .now() + limit * 100)'
# The native engine: the same idea, one file of app/Engine at a time, against
# the bench in BENCH (tests/EngineTests.swift, then tests/BackendTests.swift).
BENCH=(tests/EngineTests.swift)
engine_mutant() { # <file in app/Engine> <name> <original text> <broken text>
  rm -rf "$T/Engine"; cp -R "$ROOT/app/Engine" "$T/Engine"
  python3 - "$ROOT/app/Engine/$1" "$T/Engine/$1" "$3" "$4" <<'PY' || { echo "ERROR: the snippet for mutant '$2' is no longer in $1"; ALIVE=$((ALIVE+1)); return; }
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if a not in s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
  local files=(); for f in "${BENCH[@]}"; do files+=("$ROOT/$f"); done
  if ! swiftc -parse-as-library "$T"/Engine/*.swift "${files[@]}" -o "$T/e" 2>"$T/err"; then
    echo "ERROR: mutant '$2' does not compile"; tail -3 "$T/err"; ALIVE=$((ALIVE+1)); return; fi
  if "$T/e" >/dev/null 2>&1; then echo "SURVIVED: $2"; ALIVE=$((ALIVE+1)); else echo "killed: $2"; fi
}
engine_mutant Sound.swift "silence threshold off" 'x >= silenceDB else' 'x >= silenceDB - 10 else'
engine_mutant Sound.swift "a frozen meter reads as the last value" 'if age > Sound.staleSeconds {' 'if age > Sound.staleSeconds * 100 {'
engine_mutant Sound.swift "gaps from 50% instead of 40%" 'if pct >= 40 { return (.gaps' 'if pct >= 50 { return (.gaps'
engine_mutant Sound.swift "dead microphone never dead" '(pct >= 90 ? .dead : .ok' '(pct >= 101 ? .dead : .ok'
engine_mutant Sound.swift "no 10 s window" 'if window.count > 10 { window.removeFirst() }' 'if window.count > 1 { window.removeFirst() }'
engine_mutant Sound.swift "a gap skips seconds" 'while s > second { close(at: startedAt! + Double(second + 1)) }' 'if s > second { second = s - 1; close(at: startedAt! + Double(second + 1)) }'
engine_mutant Files.swift "evidence stops at the first block" 'hasher.update(data: d)' 'hasher.update(data: d); break'
engine_mutant Files.swift "collision overwrites" 'while exists(out) {' 'while false && exists(out) {'
engine_mutant Writer.swift "no fragments: a crash loses the file" 'writer.movieFragmentInterval = CMTime(seconds: s.fragment, preferredTimescale: 600)' ''
engine_mutant Writer.swift "the microphone track is never added" 'micIn = s.microphone ? AVAssetWriterInput' 'micIn = false ? AVAssetWriterInput'
# The backend: the verdicts the app acts on.
BENCH=(app/Setup.swift tests/BackendTests.swift)
engine_mutant Backend.swift "no microphone sample counts as live" 'micOk = !mic.isEmpty &&' 'micOk = mic.isEmpty ||'
engine_mutant Backend.swift "class mode demands a microphone" 'if meeting && micName == nil {' 'if micName == nil {'
engine_mutant Backend.swift "the disk minimum is ignored at start" 'if let f = free, f < s.minGB {' 'if let f = free, f < 0 {'
engine_mutant Backend.swift "a second stop saves (and hooks) again" 'defer { try? fm.removeItem(atPath: fileRec); try? fm.removeItem(atPath: modeRec) }' ''
engine_mutant Backend.swift "a crash leaves no signal for the watchdog" 'return FileManager.default.fileExists(atPath: fileRec)' 'return false'
engine_mutant Backend.swift "a stalled meter reads as room silence" 'case "NO_SOUND" where snap.meterAge > Sound.staleSeconds:' 'case "NO_SOUND" where false:'
engine_mutant Backend.swift "the test take gets evidence" 'if !testTake { afterSave(path, s) }' 'afterSave(path, s)'
engine_mutant Backend.swift "the test take is left on disk" 'try? FileManager.default.removeItem(atPath: file)' ''
engine_mutant Backend.swift "silence counts as 0 dB in the mean" '($1.isFinite ? pow(10, Double($1) / 10) : 0)' '($1.isFinite ? pow(10, Double($1) / 10) : 1)'
engine_mutant Texts.swift "an argument is filled twice" 'out += a[n - 1]; i += 2' 'out += a[n - 1]; i += 2; out = fill(out, a)'
echo
[ "$ALIVE" -eq 0 ] && echo "all mutants killed" || echo "$ALIVE mutant(s) alive"
[ "$ALIVE" -eq 0 ]
