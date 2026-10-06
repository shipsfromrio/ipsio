# Ipsio

Records classes and meetings on a Mac **with sound**: the screen, the
computer's audio and, in meeting mode, your voice on a separate track. Start
and stop it from the menu next to the clock, or let it run **by itself from
your calendar**: every meeting with a Meet, Zoom, Teams or Webex link is
recorded from start to end, with its name in the file.

The name comes from *ipsis verbis*: exactly as it was said.

*Em português: [LEIAME.md](LEIAME.md).*

## What it solves

macOS does not record its own sound. Shift+Cmd+5 and QuickTime record a silent
screen, and you find out at the end of the day. Ipsio records screen and sound
inside the app, through ScreenCaptureKit, with no driver and no extra tools,
and checks while it records:

| What goes wrong | How it shows | What Ipsio does |
|---|---|---|
| Recording with Shift+Cmd+5 / QuickTime | 8 h of video, 228 GB, zero audio | takes the computer's sound straight from macOS, in the same stream as the screen |
| Zoom sends sound to the speaker IT picked | a whole morning at -91 dB | records what the Mac plays, on whatever speaker; nothing to pick in Zoom, Teams or Meet, and the sound output is never touched |
| Checking "there is an audio track" | the track existed, and was silent | measures VOLUME, one sample per second, from the same buffers that go into the file |
| Finding the silence at the end | hours of nothing | yellow icon and an alert after 90 s of silence |
| Microphone without permission | macOS raises no error: it delivers digital silence | microphone below -80 dB = dead (a voice is near -32 dB, an empty room near -60); alert within 90 s |
| Your voice hiding a silent computer track | a mix sounds fine, the others are missing | nothing is mixed on disk: computer and microphone are separate tracks, and the meter, the check and the test read the computer track alone |
| The Mac sleeps or the display turns off | black or cut recording | idle sleep and display sleep held off while recording; Mac kept awake with a meeting coming |
| macOS stops the capture (permission removed, display gone) | the file stops growing, silently | the app sees the stream stop and tells you why |
| The app or the Mac goes down mid-recording | an `.mp4` cut short does not open | fragmented `.mov`, written in 2 s pieces: it plays up to the last one, and on the next launch Ipsio closes it and says so |
| Starting with no permission, folder or disk | found out at the end | a preflight that REFUSES, with the reason in words |
| A weekly meeting in the calendar | reading only the first slot records one week and misses the rest | reads the repeat rule, exceptions, moved and cancelled occurrences |

Size: at most ~1.8 GB per hour (hardware H.264, 12 fps, 4 Mbps). Only frames
where the screen changed are written, so a still slide takes far less.

## Install

Needs macOS 13 or newer and the Command Line Tools (`xcode-select --install`).
In the repository folder:

    bash install.sh

It creates a local certificate that keeps the permissions across updates,
builds the menu-bar app and starts it; the app comes back by itself at every
login. It asks for the Mac's password once (certificate). It refuses to run
while a recording is in progress, or while a recording left by a crash is
still open (open Ipsio and it closes it).

Then, once, the **Set up Ipsio** window opens by itself. It lists what Ipsio
needs, one line each, green or red, and every red line has the one button
that fixes it:

| Line | The button |
|---|---|
| Settings folder (`~/.ipsio`) | none: the text says what to check |
| Screen Recording permission | **Open Settings**: turn on "Ipsio"; the app closes and reopens by itself |
| Microphone permission | **Allow**. Required only in meeting mode or with a calendar connected; class mode records no microphone |
| Microphone for meeting mode | **Open Sound**, to connect or pick a microphone |
| Recordings folder, disk space | **Choose folder** |
| Calendar (optional) | **Connect** |

The list checks itself again every few seconds, so a line turns green as soon
as it is fixed, wherever it was fixed. When every required line is green, it
offers **Test now (10 s)**: records, the Mac speaks a sentence, measures,
deletes and gives the verdict (in meeting mode it also checks the
microphone). Nothing to set up in Zoom, Teams or Meet.

The window opens again at launch whenever something required goes missing,
and any time from the menu, **Check setup**.

## Use

The circle next to the clock: white when stopped, red when recording, yellow
with an exclamation mark when the sound (or the microphone) is gone for 90 s.

- **Record now / Stop and save.** On stop, the verdict for the whole
  recording comes right away: `sound OK (average -20 dB, silence 3% of
  the time)`, `RECORDING SAVED, BUT SILENT` or `RECORDING SAVED, WITH SOUND
  GAPS`. A clean recording becomes a notification; a problem becomes a popup.
- **Check the sound so far.** Reads the live meter: the average level of the
  recording so far, and its peak, in no time (the file is not decoded).
- **Mode.** *Class*: computer sound only. *Meeting*: computer sound + your
  microphone (the system default input). A meeting file has two audio tracks:
  **1** computer (the others), **2** microphone (you). QuickTime plays both
  together; the separate tracks let a transcription know who spoke.
- **Upcoming recordings.** What the calendar will record. Clicking a meeting
  skips (or un-skips) just that one; skipping the one being recorded stops it
  right away. Stopping a calendar recording by hand also counts as skipping.
- **Title, Folder, Recent recordings, Language (pt/en).** Files go to
  `~/Movies/Ipsio/YYYY-MM-DD_HH-MM Title.mov`.

The recording lives inside the app. Quit, logout and shutdown stop and save
it first, and **Restart the app** is greyed out while recording. If the app or
the Mac goes down, the fragments up to the last 2 s stay on disk, and on the
next launch Ipsio closes that file, writes its `.sha256` and tells you.

From Terminal:

    ipsio-calendar            # what the calendar would record now

## Calendar: recording by itself

Every 5 minutes the app reads the configured sources. Each meeting is recorded
from 2 minutes before the start to 5 minutes after the end, in meeting mode.
Back-to-back meetings become two files: the first one keeps recording until
its scheduled end, then the second takes over. An invite that overlaps the
meeting being recorded never cuts it; if it ends after it, it takes over at
that end. A recording started by hand is never stopped or replaced by the
calendar. If a reading fails (network, for example), the last good reading
still counts, and the menu says since when. After 2 hours without a full
reading, the menu line turns into a warning and a notification says why: a
meeting added since would be missed. With a meeting in the next 15
minutes the Mac does not idle-sleep.

Sources (you can use more than one; no credential lives in the code):

| Source | How to turn it on | What is kept |
|---|---|---|
| **Mac Calendar** (every account already in the Calendar app) | menu, **Connect calendar…**, **Mac's Calendar**, then **Allow** (or `CALENDAR_MACOS=1` in the conf) | same filters as iCal; no address to paste, nothing leaves the Mac |
| **Secret iCal** (Google, Outlook, iCloud) | menu, **Connect calendar…**, paste the address (or write it in `~/.ipsio/calendar.url`, one per line) | events with a Meet, Zoom, Teams or Webex link; not all-day, cancelled, or declined by you (with `CALENDAR_ME`) |
| **List** | `~/.ipsio/calendar.txt`, lines `YYYY-MM-DD HH:MM HH:MM Name` | everything |
| **Command** | `CALENDAR_COMMAND='...'` in the conf; it prints lines in the list format | everything; the door for a calendar behind its own credential (OAuth, a company API): the credential stays in your program. Killed after 60 s |

In Google Calendar, the iCal address is in Settings, your calendar,
"Integrate calendar", **Secret address in iCal format**. It gives read access
to the whole calendar to anyone who has it, so **Connect calendar…** takes it
in a password field, reads it once, saves it only if it answered with a
calendar (a bad paste never replaces one that works), and writes
`calendar.url` readable only by you (`chmod 600`). Ipsio never prints it, not
even in error messages. To check before trusting it:

    ipsio-calendar

Known limit: Outlook feeds may use Windows time-zone names
(`E. South America Standard Time`). Ipsio does not read `VTIMEZONE` blocks
yet, so such an event falls back to the Mac's time zone, with a warning in the
menu. It is right as long as the Mac and the calendar share a time zone.

## Configuration

`~/.ipsio/conf`, shell format. The menu writes it; editing by hand works too.

| Key | Default | What it is |
|---|---|---|
| `MODE` | `class` | `class` or `meeting` |
| `TITLE` | empty | goes into the name of manual recordings |
| `RECORDINGS_DIR` | `~/Movies/Ipsio` | where the `.mov` files go |
| `MIN_FREE_GB` | `20` | below this, it refuses to start |
| `UI_LANGUAGE` | system language | `pt` or `en` |
| `CALENDAR_AUTO` | `1` | `0` turns automatic recording off (the list stays in the menu) |
| `CALENDAR_BEFORE_MIN` / `CALENDAR_AFTER_MIN` | `2` / `5` | margins around each meeting |
| `CALENDAR_MODE` | `meeting` | mode of calendar recordings |
| `CALENDAR_ME` | empty | your calendar e-mail, to skip what you declined |
| `CALENDAR_LINK_ONLY` | `1` | `0` also records iCal events without a link |
| `CALENDAR_MACOS` | empty | `1` reads the Mac Calendar app (above) |
| `CALENDAR_COMMAND` | empty | command source (above) |
| `POST_RECORDING` | empty | command run after each saved recording, with the `.mov` as `$1` (see below) |

The meeting microphone is the system default input: pick it in System
Settings, Sound, Input. `CALENDAR_COMMAND` and `POST_RECORDING` exist only in
the build from this repository; the App Store edition runs no commands.

### After each recording

Every saved recording gets, next to it, a `.sha256` file in the format that
`shasum -a 256 -c` checks: evidence that the file was not changed afterwards.
Then, if `POST_RECORDING` is set, it runs with the file as `$1`; transcription
or a copy to another disk plug in here. Both run in the background, with the
hook's output in `~/.ipsio/post-recording.log` (with the exit code); a failing
command never touches the video, and stopping a recording never waits for
them. Each recording is handed over once (stopping again does not re-run it),
and the take of **Test now** never is.

    POST_RECORDING='~/bin/transcribe.sh'

## Permissions and signing

The Screen Recording and Microphone permissions belong to the **app**, not to
Terminal, and macOS binds them to the signature's designated requirement.
Signed ad hoc, that requirement changes on every build and the permission
vanishes silently (the switch shows on in Settings and does nothing).
`certificate.sh` creates, once, a certificate that only exists on this Mac, and
the requirement becomes `identifier + certificate leaf`, stable across
updates. The certificate does not need to be marked as trusted. A ghost entry
from an old signature: remove it with "−" in Settings and turn it on again.

## What it does not solve

- It only records what happens **on this Mac**. A meeting opened on the phone
  comes out as a still screen and empty sound.
- A Mac that is off, asleep with the lid closed or with the session locked
  does not record (a locked screen records the lock screen).
- A crash loses the last 2 s at most, but the meter dies with the app: a
  recording closed on the next launch is saved with no sound verdict.
- The signing key that `certificate.sh` creates sits in the System keychain,
  usable by `codesign` with no prompt (that is what lets an update re-sign
  unattended). A program already running on this Mac could sign itself as
  Ipsio and inherit its Screen Recording and Microphone permissions. A
  Developer ID certificate, or a prompt on every signature, would close it.

## The App Store edition

The same app, built by `build-store.sh` with `-D STORE`: sandboxed,
universal (Apple silicon and Intel), macOS 13 or newer. It has no LaunchAgent
(the menu item **Open at login** asks macOS instead), no `POST_RECORDING` and
no `CALENDAR_COMMAND`. It is free for 7 days with every feature, then one
in-app purchase unlocks it for life; a recording in progress always finishes.
The build from this repository is always unlocked.

## The Terminal recipe (legacy)

`ipsio.sh` is the older recipe, kept for Terminal use: it records through
ffmpeg and the BlackHole driver into `.mkv`, and needs the `Ipsio` output
device picked as the speaker inside Zoom or Teams. The app does not use it.
To set it up: `bash install.sh --with-script` (Homebrew required; asks for the
password for the driver and an audio reload). Then
`ipsio start | stop | level | check | status | test | doctor`.

## Next

Transcription with who said what (using the separate tracks) and disk cleanup
(deleting the video after N days, keeping audio and transcript) are designed
in [`docs/DESIGN.md`](docs/DESIGN.md), with no code yet.

## Develop

    bash tests/test-ipsio.sh      # the legacy script, with test doubles: runs on Linux and macOS
    swiftc -parse-as-library app/Schedule.swift tests/ScheduleTests.swift -o /tmp/t && /tmp/t
    swiftc -parse-as-library app/Setup.swift tests/SetupTests.swift -o /tmp/s && /tmp/s   # the setup checklist
    swiftc -parse-as-library app/Engine/*.swift tests/EngineTests.swift -o /tmp/e && /tmp/e   # native engine
    swiftc -parse-as-library app/Engine/*.swift app/Setup.swift tests/BackendTests.swift -o /tmp/b && /tmp/b   # the app's backend
    bash tests/mutants.sh         # plants defects in the calendar and the engine; each must fail its bench
    bash build-store.sh           # the App Store edition into dist/ (ad hoc signed; see the script for the store signature)

CI (GitHub Actions) runs `bash -n`, `shellcheck`, the benches, the mutants
and the app build on a real macOS runner.

Every recording rule lives in `app/Engine/`. `Backend.swift` answers in the
format the script always used, and the app picks icon and alarm from the
machine line `#state key=value` that ends every answer, never from the text,
which changes with the language. `tools/NativeCLI.swift` builds
`ipsio-native`, the same backend from Terminal.

## License

[GPL-3.0](LICENSE).
