# Notes for App Review

Paste the text below into "App Review Information, Notes". No demo account is
needed.

---

Hello, and thank you for reviewing Ipsio.

WHAT IT DOES
Ipsio is a menu-bar app (the circle next to the clock) that records classes
and video meetings on this Mac: the screen, the sound the Mac plays and, in
meeting mode, the user's microphone. It can also start and stop recordings
by itself from the user's calendar, for events that carry a video-call link.

WHY IT NEEDS EACH PERMISSION
- Screen Recording (ScreenCaptureKit): the screen and the system sound are
  the recording. macOS's own tools record the screen without the sound, which
  is the problem Ipsio exists to solve.
- Microphone: only in meeting mode, so the user's own voice goes into a
  separate track. Class mode works without it, even if it is declined.
- Calendars (optional): only to know when a meeting starts and ends, and its
  name. Nothing is uploaded.
- Network (client only): only to download a private iCal feed whose address
  the user pastes, directly from that calendar provider.
Everything stays on the Mac. There is no account, no server and no data
collection.

CONSENT
The app records only what happens on this Mac, and only when the user starts
it or connects a calendar. While recording, the menu-bar icon turns red and
macOS shows its own screen-recording indicator. The App Store description
reminds users that recording other people may require their consent, and so
does the app, on by default:
- A recording the user starts (menu, shortcut, or the Record button of a
  call offer) first shows "Tell them you are recording?" with a notice to
  paste in the meeting chat, and three buttons: "Copy notice and record",
  "Record", "Cancel".
- A recording the calendar starts is never held by a popup (nobody may be at
  the Mac). It starts, and a notification "Recording: tell the others"
  appears; clicking it copies the notice.
- The 10-second test never asks: it records only a sentence spoken by the
  Mac and deletes it.
The menu item "Remind me to announce the recording" turns it off.

HOW TO TEST
1. Launch Ipsio. The "Set up Ipsio" window opens. Click "Open Settings" and
   turn on Ipsio under Screen & System Audio Recording; the app closes and
   reopens by itself.
2. In the same window, click "Test now (10 s)". The Mac speaks a sentence,
   Ipsio measures the recorded sound, deletes the test file and shows the
   verdict.
3. From the menu, "Record now". Play any video with sound for a minute, then
   "Stop and save". The verdict appears, and the file is in Movies/Ipsio with
   a .sha256 file next to it.
4. Meeting mode: menu, Mode, Meeting. Allow the microphone (asked at first
   launch, or from the setup window), and record again while speaking. The file has two audio tracks (computer, then
   microphone).
5. Calendar (optional): menu, "Connect calendar...", "Mac's Calendar", Allow.
   Add an event starting in 5 minutes with the address
   https://meet.google.com/abc-defg-hij in its location or notes. It appears
   under "Upcoming recordings" and records by itself from 2 minutes before
   its start.
6. Optional: menu, "Open at login" registers Ipsio as a login item through
   macOS (SMAppService); it is off until the user ticks it.
7. Open call: join a Google Meet call in Safari or Chrome (the tab title
   reads "Meet - abc-defg-hij"). Within 15 seconds a notification offers to
   record it, once per call. It reads window titles only, through the Screen
   Recording permission already granted; it needs notifications allowed.
8. Search: after a recording is transcribed (Recent recordings, the file,
   "Transcribe"), menu, "Search recordings...", type a word that was said.
9. Integrity report: Recent recordings, the file, "Integrity report (PDF)".
   A PDF appears next to the recording; the recording and its .sha256 are
   only read.
10. What to record: menu, "Record", "A window...", pick a window; the next
   recording captures only that window. "Quality" offers Economy, Normal and
   High, with the GB per hour.
11. Shortcuts: Control-Option-Command-R records or stops, and
   Control-Option-Command-T runs the test, from any app. They use the
   standard hot key API, with no Accessibility permission.

PURCHASE
Free download with a 7-day trial, every feature included, starting at first
launch. After that, one non-consumable in-app purchase ("Ipsio lifetime",
US$ 19.99) unlocks the app for life. The menu shows the days left, "Buy Ipsio
lifetime" and "Restore purchase". When the trial ends, only new recordings
are refused: a recording in progress always finishes and is saved.

To test the purchase, use a sandbox Apple Account. No account of ours
exists.
1. On a fresh install, before the trial starts, a window states its terms:
   7 days with every feature, then no new recordings until the one-time
   purchase "Ipsio lifetime", with "Start the 7 days", "Buy now" and
   "Restore purchase". The trial starts when that window is answered.
   Then the bottom of the menu shows "Trial: 7 days left",
   "Buy Ipsio lifetime (<local price>)..." and "Restore purchase".
2. "Buy Ipsio lifetime" opens the App Store payment sheet; confirm with the
   sandbox account. A "THANK YOU" message appears and those three lines leave
   the menu: the app is unlocked.
3. After deleting and reinstalling the app (or on another Mac), "Restore
   purchase" unlocks it again with the same sandbox account. With an account
   that never bought it, Restore says "NOTHING TO RESTORE".
4. The trial counts 7 days from the first launch. When it is over, the menu
   says "Trial ended", and "Record now" shows "TRIAL ENDED", pointing to Buy
   and Restore; a recording already running is not stopped.

Thank you.
