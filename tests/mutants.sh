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
# The license (store build): the trial and the purchase.
store_mutant() { # <name> <original text> <broken text>
  rm -rf "$T/Store"; mkdir -p "$T/Store"
  python3 - "$ROOT/app/Store/License.swift" "$T/Store/License.swift" "$2" "$3" <<'PY' || { echo "ERROR: the snippet for mutant '$1' is no longer in License.swift"; ALIVE=$((ALIVE+1)); return; }
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if a not in s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
  if ! swiftc -parse-as-library "$T/Store/License.swift" "$ROOT/tests/LicenseTests.swift" -o "$T/l" 2>"$T/err"; then
    echo "ERROR: mutant '$1' does not compile"; tail -3 "$T/err"; ALIVE=$((ALIVE+1)); return; fi
  if "$T/l" >/dev/null 2>&1; then echo "SURVIVED: $1"; ALIVE=$((ALIVE+1)); else echo "killed: $1"; fi
}
store_mutant "gpl not unlocked" 'if build == .gpl { return .unlocked(.gpl) }' ''
store_mutant "purchase ignored" 'if purchased { return .unlocked(.purchased) }' ''
store_mutant "day 7 still trial" 'if left <= 0 { return .expired }' 'if left < 0 { return .expired }'
store_mutant "last seen ignored (clock back extends trial)" 'max(now, lastSeen ?? now)' 'now'
store_mutant "clock before first launch grants more than 7 days" 'let elapsed = max(0, effective.timeIntervalSince(firstLaunch))' 'let elapsed = effective.timeIntervalSince(firstLaunch)'
store_mutant "latest first launch wins" 'let first = firsts.min() ?? now' 'let first = firsts.max() ?? now'
store_mutant "defaults ignored (deleting the file resets the trial)" 'let firsts = [f.first, defaultsDate(Self.firstKey)].compactMap { $0 }' 'let firsts = [f.first].compactMap { $0 }'
store_mutant "last seen not persisted" 'let seen = max(seens.max() ?? now, now)' 'let seen = now'
store_mutant "trial blocks recording" 'if case .expired = s { return false }' 'if case .trial = s { return false }'
# Transcription: the windows, the overlap and who is speaking.
transcribe_mutant() { # <file in app/Transcribe> <name> <original text> <broken text>
  rm -rf "$T/Transcribe"; cp -R "$ROOT/app/Transcribe" "$T/Transcribe"
  python3 - "$ROOT/app/Transcribe/$1" "$T/Transcribe/$1" "$3" "$4" <<'PY' || { echo "ERROR: the snippet for mutant '$2' is no longer in $1"; ALIVE=$((ALIVE+1)); return; }
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if a not in s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
  if ! swiftc -parse-as-library "$T"/Transcribe/*.swift "$ROOT/tests/TranscribeTests.swift" -o "$T/tr" 2>"$T/err"; then
    echo "ERROR: mutant '$2' does not compile"; tail -3 "$T/err"; ALIVE=$((ALIVE+1)); return; fi
  if "$T/tr" >/dev/null 2>&1; then echo "SURVIVED: $2"; ALIVE=$((ALIVE+1)); else echo "killed: $2"; fi
}
transcribe_mutant Transcript.swift "windows do not overlap" 'start += length - overlap' 'start += length'
transcribe_mutant Transcript.swift "the overlap keeps words twice" 'let lo = i == 0 ? -Double.infinity : w.start + overlap / 2' 'let lo = i == 0 ? -Double.infinity : w.start'
transcribe_mutant Transcript.swift "the microphone is the others" 'case (2, 1), (3, 2): return .me' 'case (2, 1), (3, 2): return .others'
transcribe_mutant Transcript.swift "the script's mix is transcribed" 'case (1, 0), (2, 0), (3, 1): return .others' 'case (1, 0), (2, 0), (3, 0), (3, 1): return .others'
transcribe_mutant Export.swift "a transcript may overwrite the evidence" 'if kinds.contains(ext) || ext == "sha256" { throw Failure.refused(media) }' ''
# One file of app/ against its own bench (with Files.swift for the evidence hash):
# meeting detection, search, the consent reminder and the integrity report.
app_mutant() { # <file in app> <bench in tests> <name> <original text> <broken text>
  mkdir -p "$T/app"
  python3 - "$ROOT/app/$1" "$T/app/$1" "$4" "$5" <<'PY' || { echo "ERROR: the snippet for mutant '$3' is no longer in $1"; ALIVE=$((ALIVE+1)); return; }
import sys
src, dst, a, b = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if a not in s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
  if ! swiftc -parse-as-library "$T/app/$1" "$ROOT/app/Engine/Files.swift" "$ROOT/tests/$2" -o "$T/ap" 2>"$T/err"; then
    echo "ERROR: mutant '$3' does not compile"; tail -3 "$T/err"; ALIVE=$((ALIVE+1)); return; fi
  if "$T/ap" >/dev/null 2>&1; then echo "SURVIVED: $3"; ALIVE=$((ALIVE+1)); else echo "killed: $3"; fi
}
D=MeetingDetectTests.swift
app_mutant MeetingDetect.swift $D "Zoom running counts as a meeting" 'if zoom.contains(id) {' 'if zoom.contains(id) { if true { return Meeting(app: "Zoom", key: "zoom") }'
app_mutant MeetingDetect.swift $D "a Zoom tab name counts (substring, not words)" 'for i in 0...(w.count - p.count) where Array(w[i..<(i + p.count)]) == p { return true }' 'if w.joined(separator: " ").contains(p.joined(separator: " ")) { return true }'
app_mutant MeetingDetect.swift $D "the Meet home page counts" 'if isBrowser(id), let c = meetCode(title) {' 'if isBrowser(id), words(title).contains("meet") { let c = meetCode(title) ?? "home";'
app_mutant MeetingDetect.swift $D "a Teams chat counts" 'if ["chat", "calendar", "calendario", "activity", "atividade", "teams", "equipes"].contains(w[0]) { return nil }' ''
app_mutant MeetingDetect.swift $D "a Slack channel named huddle counts" 'if lead.hasPrefix("huddle"), w[0] == "huddle" {' 'if !lead.isEmpty, w.contains("huddle") {'
app_mutant MeetingDetect.swift $D "a window of an app not running counts" 'for win in windows where running.contains(win.bundleID) {' 'for win in windows where !running.isEmpty || true {'
app_mutant MeetingDetect.swift $D "debounce offers twice" 'if handled.contains(m.key) { return nil }' ''
app_mutant MeetingDetect.swift $D "debounce never forgets" 'lastSeen[k] = nil; handled.remove(k)' 'lastSeen[k] = nil'
app_mutant MeetingDetect.swift $D "offered while recording" 'return recording || calendarSoon ? nil : m' 'return calendarSoon ? nil : m'
app_mutant MeetingDetect.swift $D "the calendar margin is ignored" 'now >= $0.start.addingTimeInterval(-margin)' 'now >= $0.start'
D=SearchTests.swift
app_mutant Search.swift $D "search becomes accent-sensitive" 's.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()' 's.lowercased()'
app_mutant Search.swift $D "OR instead of AND" 'return terms.allSatisfy { f.contains($0) }' 'return terms.contains { f.contains($0) }'
app_mutant Search.swift $D "the limit is ignored" 'out.append(h.element)
                if out.count >= limit { return out }' 'out.append(h.element)'
app_mutant Search.swift $D "oldest recording first" '$0.date != $1.date ? $0.date > $1.date' '$0.date != $1.date ? $0.date < $1.date'
app_mutant Search.swift $D "file names are not searched" 'if matches((name as NSString).deletingPathExtension, q) {' 'if false {'
app_mutant Search.swift $D "the offset drops the hours" 'return (h * 3600 + m * 60 + s,' 'return (h * 0 + m * 60 + s,'
app_mutant Search.swift $D "the speaker label is searched" 'guard let p = parse(line), matches(p.text, q) else { continue }' 'guard let p = parse(line), matches(line, q) else { continue }'
app_mutant Search.swift $D "a hit points at the .txt next to a recording" 'let shown = r.entry.media ?? r.entry.txt!' 'let shown = r.entry.txt ?? r.entry.media!'
app_mutant Consent.swift ConsentTests.swift "a calendar recording shows a popup" 'return .notification' 'return .dialog'
app_mutant Consent.swift ConsentTests.swift "the test take reminds" 'case .test: return .none' 'case .test: return .dialog'
app_mutant Consent.swift ConsentTests.swift "turned off still reminds" 'guard enabled else { return .none }' ''
app_mutant Consent.swift ConsentTests.swift "the same meeting is reminded at every restart" 'if let id = eventID, alreadyReminded.contains(id) { return .none }' ''
app_mutant Consent.swift ConsentTests.swift "class mode gets the meeting notice" 'mode == "class" ? "notice_class"' 'mode == "lecture" ? "notice_class"'
app_mutant Consent.swift ConsentTests.swift "the reminder is off by default" 'conf[confKey] != "0"' 'conf[confKey] == "1"'
app_mutant Report.swift ReportTests.swift "the PDF omits the hash" 'draw(isCode(f.value) ? attr(f.value, font: "Menlo-Regular"' 'draw(isCode(f.value) ? attr("", font: "Menlo-Regular"'
app_mutant Report.swift ReportTests.swift "a report for the evidence file itself" 'guard recordings.contains(ext) else { throw Failure.refused(path) }' ''
app_mutant Report.swift ReportTests.swift "the report is written over the recording" '{ (media as NSString).deletingPathExtension + ".integrity.pdf" }' '{ media }'
app_mutant Report.swift ReportTests.swift "a different .sha256 reads as a match" 'return hex == n ? .match(n)' 'return true ? .match(n)'
app_mutant Report.swift ReportTests.swift "a missing .sha256 is invented" 'guard let ev = evidence else' 'guard let ev = evidence ?? now.map({ "\($0)  \(name)" }) else'
app_mutant Report.swift ReportTests.swift "a .sha256 of another file is accepted" 'named == name else' 'true else'
app_mutant Report.swift ReportTests.swift "a copy's creation date wins over the name" 'c >= n && c < n.addingTimeInterval(60)' 'c >= n'
# Quality presets and what to record.
BENCH=(tests/CaptureTests.swift)
engine_mutant Quality.swift "an unknown quality records high" '?? .normal' '?? .high'
engine_mutant Quality.swift "the normal preset changes its fps" 'case .normal: return 12;' 'case .normal: return 15;'
engine_mutant Quality.swift "a meeting counts one audio track" '(meeting ? 2 : 1)' '(meeting ? 1 : 1)'
engine_mutant Target.swift "a window gone records the whole screen" '? .window(id) : .windowGone' '? .window(id) : main(false)'
engine_mutant Target.swift "a display gone is an error instead of main" '? .display(id, fellBack: false) : main(true)' '? .display(id, fellBack: false) : .noDisplay'
engine_mutant Target.swift "a display gone falls back silently" '? .display(id, fellBack: false) : main(true)' '? .display(id, fellBack: false) : main(false)'
engine_mutant Target.swift "a window is written to the conf" 'case .window: return nil' 'case .window(let id): return "window:\(id)"'
engine_mutant Target.swift "a window keeps odd or oversized sides" 'return Recorder.fit(px(width), px(height))' 'return (px(width), px(height))'
BENCH=(app/Setup.swift tests/BackendTests.swift)
engine_mutant Backend.swift "the preset never reaches the capture" 'o.fps = s.quality.fps; o.videoBitrate = s.quality.videoBitrate; ' ''
engine_mutant Backend.swift "the disk minimum ignores the preset" 'minGB: q.minFreeGB(Int(c["MIN_FREE_GB"] ?? "") ?? 20, meeting: m == "meeting"),' 'minGB: Int(c["MIN_FREE_GB"] ?? "") ?? 20,'
engine_mutant Backend.swift "a window in the conf is honored" 'CaptureTarget.parse(oneShot: env["IPSIO_TARGET"]) ?? CaptureTarget.parse(conf: c["CAPTURE_TARGET"])' 'CaptureTarget.parse(oneShot: env["IPSIO_TARGET"] ?? c["CAPTURE_TARGET"]) ?? .main'
engine_mutant Backend.swift "a gone window reads as a failed start" '            case .windowGone: return t("window_gone")' '            case .noDisplay where false: return t("window_gone")'
engine_mutant Backend.swift "a display fallback is not said" 'target = "main_fallback"; out.append(t("display_gone"))' 'target = "main"'
echo
[ "$ALIVE" -eq 0 ] && echo "all mutants killed" || echo "$ALIVE mutant(s) alive"
[ "$ALIVE" -eq 0 ]
