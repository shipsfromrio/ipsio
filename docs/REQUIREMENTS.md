# Requirements from real use

Each requirement here was paid for by a recording that went wrong, or nearly
did, on Macs that record meetings every day (Aug to Oct 2026). For each one:
what must hold, why (the measured case, with no personal data), where Ipsio
stands today, and the bench that proves it or the issue that will.

"Script" means `ipsio.sh` (ffmpeg + BlackHole, what the app runs today).
"Engine" means the native ScreenCaptureKit recorder in `app/Engine/`
(phase 1 built, not yet called by the app; see `docs/DESIGN.md`, section 3).

| # | Requirement | Script | Engine | Proof or issue |
|---|---|---|---|---|
| R1 | A missed calendar recording is never silent | missing | missing | [#3](https://github.com/shipsfromrio/ipsio/issues/3) |
| R2 | The meeting's sound reaches the recorder, or an alarm in 90 s | covered | covered by design | `test-ipsio.sh`, `EngineTests` |
| R3 | The live meter reads the computer track alone, never the mix | covered | covered | `test-ipsio.sh` (strengthened here) |
| R4 | Track layout and container are a stable contract | covered | diverges | `test-ipsio.sh`; [#4](https://github.com/shipsfromrio/ipsio/issues/4) |
| R5 | A recording outlives the app and its windows | covered | regresses | [#5](https://github.com/shipsfromrio/ipsio/issues/5) |
| R6 | No lost frames on a Mac under full CPU load | not measured | not measured | [#7](https://github.com/shipsfromrio/ipsio/issues/7) |
| R7 | The original is evidence: hashed, untouched, start time kept | partial | partial | [#8](https://github.com/shipsfromrio/ipsio/issues/8) |
| R8 | A meeting that runs late is not cut at the invite's end | missing | missing | [#6](https://github.com/shipsfromrio/ipsio/issues/6) |
| R9 | What would refuse at the start is said before the meeting | missing | missing | [#9](https://github.com/shipsfromrio/ipsio/issues/9) |

## R1. A missed calendar recording is never silent

**Must hold.** If a calendar meeting's whole recording window passes while
Ipsio is not running (the Mac was off, restarting, or nobody logged in), the
next launch says so: which meeting, and why. When calendar recording is on and
the Mac has no automatic login, setup shows it as a red line.

**Why.** The app runs inside a user session, and screen capture needs one. A
recording Mac restarted three times in five days (03:15, 08:22 and 12:05),
with automatic login off. After the 03:15 restart a meeting at 08:58 was not
recorded, and it was noticed by hand a minute later. The other two times
someone happened to log in. Nothing in the recorder would have said anything.

**Today.** `Schedule.target()` (`app/Schedule.swift`) starts a meeting that is
already in progress when the app comes back, so a restart in the middle of a
meeting is covered. A meeting entirely inside the gap is not reported (#3).
A `doctor` line for a missing automatic login is in progress in a separate
change. Ipsio must detect and tell, never change the login setting itself
(with FileVault on, automatic login is impossible, and the line says so).

## R2. The meeting's sound reaches the recorder, or an alarm within 90 s

**Must hold.** With the script, the meeting app's own speaker setting must be
the `Ipsio` output device (or the device named in `OUTPUT_DEVICE`); a silent
computer track turns the icon yellow and raises an alert after 90 s.

**Why.** Zoom, Teams and Google Meet each keep their own speaker choice and
ignore the system output. A whole morning was recorded at -91 dB because only
the system output was switched, and on 06/10/2026 a 46-minute Meet call was
recorded with a silent computer track for the same reason, the microphone
alone coming through at -53 dB.

**Today.** Covered for the script: the meter (`ipsio.sh`, `level`), the
silence summary (`SILENT` at 90% or more, `GAPS` at 40%) and the alarm
(`app/Ipsio.swift`, `silenceThreshold = 90`). The engine captures system
sound directly, with the output untouched, so the speaker trap does not exist
there; its silence verdicts are pinned by `tests/EngineTests.swift` and the
engine mutants. Two gaps, both in progress in a separate change: a bench
that pins the 90 s threshold itself, and an `ON_ALARM` hook so the alarm can
reach someone who is not looking at the Mac. The README and LEIAME still say
Meet in the browser follows the system output; the 06/10 recording
contradicts that, and the fix is part of the same change.

## R3. The live meter reads the computer track alone

**Must hold.** In meeting mode the meter that raises the silence alarm reads
the computer sound only. The microphone has its own meter, for a dead
microphone.

**Why.** An earlier recorder read the mix. The voice of the person at the Mac
kept the mix above the silence threshold, and a silent computer track (the
other participants) went unnoticed until the end.

**Today.** Covered. Script: the filter graph splits the computer input into
`[s1][s2][s3]` and meters `[s3]`; the mix (`[mix]`) only goes to the file.
Engine: two separate `Meter`s (`app/Engine/Recorder.swift`), nothing mixed.
Bench: `tests/test-ipsio.sh` checks that the meter's branch comes from the
split of the computer input and that the mix feeds no meter. Until this
change the negative check looked for a `[met]` label that no version of the
script ever had, so it could not fail.

## R4. Track layout and container are a stable contract

**Must hold.** Tools downstream read a recording by track index. In meeting
mode the file has: track 1 = mix, 2 = computer (the others), 3 = microphone
(you). Any change to the layout or to the container is either avoided or
declared next to the file, and announced.

**Why.** A post-meeting pipeline built on this layout copies the file,
extracts tracks 2 and 3, transcribes each with the wall-clock time of every
line, and interleaves them as `[time] [OTHERS] ...` / `[time] [ME] ...`.
Separate tracks are speaker separation with no model, for two ends of a call.
It finds recordings by their `.mkv` name.

**Today.** The script keeps the layout, now pinned by `test-ipsio.sh`
(`-map [mix] -map [s2] -map [m2]`, in that order). The engine writes a
fragmented `.mov` with track 1 = computer and track 2 = microphone, no mix
(`app/Engine/Writer.swift`). Phase 2 as designed would make that pipeline
transcribe the microphone as "the others", find no track 3, and find no
`.mkv`, with no error anywhere. Decision and bench: #4.

## R5. A recording outlives the app and its windows

**Must hold.** Quitting, crashing or restarting the menu-bar app, closing a
window, or the app restarting itself after a permission change, never stops
or loses a recording. A calendar that changes while the app is down is read
again when it comes back.

**Why.** An earlier recorder ran its schedule as a long-lived shell in a
Terminal window. Closing the window, a logout or a restart killed it in
silence, and it needed a separate watcher that reopened the schedule every 5
minutes. A meeting stopped by hand was then reopened by the watcher, until
manual stops were recorded as closed.

**Today.** Covered for the script: ffmpeg and `caffeinate` run under `nohup`
(`ipsio.sh`, `start`), the app finds the recording again through
`~/.ipsio/pid`, and the LaunchAgent has `RunAtLoad` and `KeepAlive`
(`install-app.sh`). The calendar is read every 5 minutes by the app itself, a
meeting in progress is resumed by `Schedule.target()`, and stopping a calendar
recording by hand counts as skipping it. No bench covers the app's
reattach. The engine records in the calling process, so phase 2 would
regress this: #5. When the engine is wired to the app it also needs what the
script gets for free: `caffeinate` tied to the recorder's life, and a
`didStopWithError` from ScreenCaptureKit handled as "the recorder died"
(alert with the reason, the same as a dead ffmpeg), never as a quiet stop.

**One scheduler per Mac.** A Mac that moves to Ipsio from an earlier
recorder must not keep two schedules alive: both would record the same
meeting, or the old one would hold the audio device. Setup should see a
known older recorder still running and say so (in progress in the same
separate change as the `doctor` lines).

## R6. No lost frames on a Mac under full CPU load

**Must hold.** On a recording Mac whose load average equals its core count,
the recorder writes every frame and every second of audio.

**Why.** Recording Macs are not idle. One was measured at a load average of
18.9 to 23.9 on 18 cores for days, with a CI build runner on the same
machine. The engine's case (2.6% CPU against ffmpeg's 11.1%) was measured on
an idle Mac.

**Today.** Not measured for either recorder. GitHub-hosted runners have no
screen session or audio device, so the method is manual and written in #7.

## R7. The original is evidence

**Must hold.** Every saved recording has a hash next to it that `shasum -a
256 -c` checks; the original is never edited or renamed after it is saved;
tools work on copies; the exact wall-clock start of the recording is kept in
a form that survives a copy.

**Why.** Meeting recordings are used to check minutes written by someone
else, line by line. The pipeline that does it copies the file to a `.partial`
name, checks the SHA-256 on both machines, only then gives it its final name,
makes the copy read-only, and writes a receipt with both hashes, the source
and the file's birth time. It refuses a file written less than 60 s ago, or
one that grows during a short wait, because that is a recording still in
progress. It takes the start time from the birth time on the Mac (to the
second) and, when a copy lost it, from the name (to the minute).

**Today.** The `.sha256` is written after every saved recording (`ipsio.sh`,
before `POST_RECORDING`, which then gets the path). The original stays
writable, and the start time exists only as file metadata and in the name:
#8. One path in the script, a recording saved but reported as not opening,
returns before the `.sha256` is written; the fix is in progress in a
separate change. A consumer that runs from `POST_RECORDING` needs no "is it still
growing?" guess, because the hook runs after the file is closed.

## R8. A meeting that runs late is not cut at the invite's end

**Must hold.** A calendar recording that reaches its scheduled end while the
computer track still has sound keeps going, in steps, up to a cap, unless the
next meeting takes over or someone stops it.

**Why.** A three-hour evening meeting was scheduled with a 10-minute margin,
and the written instructions for the person attending had to say "if it runs
late, start another recording from the menu", because nothing else would.

**Today.** The recording stops at the end plus `CALENDAR_AFTER_MIN` (5 min):
#6.

## R9. What would refuse at the start is said before the meeting

**Must hold.** Some minutes before each calendar recording, the same checks
as `ipsio doctor` run, plus free disk for that meeting's length; a red result
becomes a notification then, with the fix.

**Why.** Before an important meeting the readiness check was a hand-written
list, run remotely the day before and again 15 minutes before: session logged
in, recorder and schedule alive, watcher loaded, free disk, machine load.
Every item could be checked by the recorder itself. The preflight refuses
with the reason in words, but for a calendar recording that refusal happens
when the meeting has already started and the person is in the call.

**Today.** The preflight runs only at `start`; the stale-calendar warning
(2 h without a full reading) is the one check that runs ahead: #9.

## Practices that are not code

- A second, independent recorder (a phone's voice recorder near the speaker)
  for any meeting that cannot be repeated. One Mac is one point of failure.
- Notes during the meeting in the form `HH:MM | who | fact`, one per line,
  with a clock in view: they line up with a wall-clock transcript later.
- A test take (`Test now`, or `ipsio test`) on the Mac that will record, the
  day before, with the meeting app's speaker already set.
