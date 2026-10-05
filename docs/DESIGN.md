# Design: transcription with speakers, and disk cleanup

No code yet. This file exists so the code is born in the right order:
determinism before AI, and measurement before trust.

## 1. Transcription with who said what

### What already exists and changes everything

A meeting recording has three audio tracks: **1** mix, **2** computer only
(the others), **3** microphone only (you). So "who spoke" has a part that
**needs no AI**: whatever is on track 3 is you. Voice-separation AI
(diarization) only comes in to split track 2 among the other people, and only
when there is more than one.

### Steps

1. **Extract** (ffmpeg, deterministic): tracks 2 and 3 as mono, 16 kHz.
   `ffmpeg -i X.mkv -map 0:a:1 -ac 1 -ar 16000 others.wav` and `-map 0:a:2`
   for `me.wav`.
2. **Where there is speech** (deterministic): the meter that already runs
   during the recording can be extended to keep each track's per-second RMS
   next to the `.mkv`; a speech segment = a stretch above each track's
   threshold. No AI VAD in the first version.
3. **Leakage** (deterministic): without headphones, the microphone hears the
   speaker, and the others' voices also show up on track 3, quieter and a few
   milliseconds late. A stretch of track 3 that correlates with track 2 (delay
   0 to 100 ms, correlation above a measured threshold) is echo, not you, and
   goes out.
4. **Text** (local AI): Whisper (`large-v3-turbo` through `mlx-whisper` on
   Apple Silicon, or `whisper.cpp`) on each separate track, with per-word
   timing. Never on the mix: on the mix two people talking at once become a
   single sentence.
5. **Who, among the others** (AI, optional): diarization on track 2 only.
   Labels `Person 1..N`, never invented names; a name only goes in if the user
   gives it.
6. **Join** (deterministic): sort the segments by time and write, next to the
   video, `... .transcript.md` (readable), `.vtt` (subtitles) and `.json`
   (machine: track, start, end, text, confidence).

### Measure before trusting

A test meeting, with no third-party data, with a hand-reviewed reference.
Measures: WER per track (text), speaker-attribution error per second, and
processing time per minute of audio. Automatic transcription is only on by
default after the numbers are written here. If the user already has a
transcriber (a folder watcher, for example), the hook is the same:

### Hook

Built (05/10/2026). `POST_RECORDING='command'` in the conf: `ipsio.sh stop`
runs the command after each saved recording (manual, calendar or Terminal
alike), after writing the `.sha256` evidence file, with the `.mkv` path as `$1`,
in the background, and logs the output and exit code to
`~/.ipsio/post-recording.log`. A failing command never touches
the video. Both the built-in transcription and any outside transcriber plug in
through this hook.

## 2. Disk cleanup

An hour of meeting takes ~1.8 GB of video and ~60 MB for the three audio
tracks. After a few days, the video is rarely what one looks for.

### Command

    ipsio cleanup [--days N] [--apply]

A dry run by default: lists what it would do and how much it frees. With
`--apply`, for each `.mkv` older than N days (`CLEANUP_DAYS`, default 30):

1. extracts ALL audio tracks without re-encoding:
   `ffmpeg -i X.mkv -map 0:a -c copy X.audio.mka`;
2. checks the copy before deleting anything (fail closed): same number of
   audio tracks and the same duration as the video within 1 s;
3. if `CLEANUP_REQUIRES_TRANSCRIPT=1`, only goes on if the transcript exists;
4. moves the `.mkv` to the Trash (never deletes directly): the user can still
   change their mind until the Trash is emptied.

It never touches the recording in progress (the file in `~/.ipsio/file` with
the recorder alive), nor any file that does not follow Ipsio's name pattern.
It can run by hand or from a daily LaunchAgent; the menu gains "Cleanup: frees
X GB".

### Bench

The same standard as the rest: ffmpeg and ffprobe doubles, one case per
refusal (missing track, different duration, no transcript, recording in
progress, name outside the pattern) and mutants that require it to fail a
cleanup that deletes without checking.

## 3. Native engine (no BlackHole, no ffmpeg)

The App Store build cannot ship a driver, Homebrew tools or a script, so the
recorder moves to ScreenCaptureKit + AVAssetWriter inside the app.
`tools/sck-probe.swift` is the phase-0 probe: main display + system sound +
microphone into a fragmented `.mov`, with the same settings as `ipsio.sh`
(12 fps, H.264 on the video chip at 4 Mbps, AAC 128k).

### Measured on 05/10/2026 (Apple M5 Max, macOS 26.6, 60 s, a sound playing and windows opening)

| | ffmpeg (meeting mode, today) | native probe |
|---|---|---|
| CPU, average | 11.1% | 2.6% |
| memory, average | 194 MB | 72 MB |
| file for 60 s | 11.8 MB | 1.4 MB (frames only when the screen changes) |
| system sound | needs BlackHole and the output switched | captured directly (-19 dB peak), output untouched |
| `kill -9` at 15 s | `.mkv` survives | `.mov` survives: plays and decodes to the last 2 s fragment |
| start offset mic vs video | n/a | 0.07 s (one host clock) |

Gate passed on CPU, memory and crash survival. Still to measure: alignment
over a 2 h recording, and a run on macOS 13.
