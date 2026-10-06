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
reminds users that recording other people may require their consent. We
intend to add a reminder at the start of each meeting recording, suggesting
the user tell the participants.

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

PURCHASE
Free download with a 7-day trial, every feature included, starting at first
launch. After that, one non-consumable in-app purchase ("Ipsio lifetime",
US$ 19.99) unlocks the app for life. The menu shows the days left, "Buy Ipsio
lifetime" and "Restore purchase". When the trial ends, only new recordings
are refused: a recording in progress always finishes and is saved. The
purchase can be tested with a sandbox account; no account of ours exists.

Thank you.
