# Notes for App Review

Paste the text below, as is, into "App Review Information, Notes". Apple's limit is 4000 bytes;
this text is 3460. `docs/store/connect.md` carries the same block.

---

Hello, and thank you for reviewing Ipsio. No demo account is needed.

WHAT IT DOES
Ipsio is a menu-bar app (the circle next to the clock) that records classes and video meetings on this Mac: the screen, the sound the Mac plays and, in meeting mode, the microphone. It can also record by itself from the user's calendar, for events with a video-call link.

PERMISSIONS
- Screen Recording (ScreenCaptureKit): the screen and the system sound are the recording.
- Microphone: meeting mode only, in a separate track. Class mode works without it.
- Calendars (optional): to know when a meeting starts and ends, and its name.
- Network (client only): to download a private iCal feed whose address the user pastes.
Everything stays on the Mac. No account, no server, no data collection.

CONSENT
Ipsio records only when the user starts it or connects a calendar. While recording, the menu-bar icon turns red and macOS shows its own indicator. Before a recording the user starts, "Tell them you are recording?" offers a notice to paste in the meeting chat, with "Copy notice and record", "Record" and "Cancel". A recording the calendar starts is never held by a popup: a notification "Recording: tell the others" copies the notice. The menu item "Remind me to announce the recording" turns this off.

HOW TO TEST
1. Launch Ipsio. In "Set up Ipsio", click "Open Settings" and turn on Ipsio under Screen & System Audio Recording. The app reopens by itself.
2. Click "Test now (10 s)". The Mac speaks a sentence, Ipsio measures it, deletes the test file and shows the verdict.
3. Menu, "Record now". Play a video with sound for a minute, then "Stop and save". The file is in Movies/Ipsio, with a .sha256 file next to it.
4. Menu, Mode, Meeting. Allow the microphone and record while speaking. The file has two audio tracks (computer, then microphone).
5. Optional: menu, "Connect calendar...", "Mac's Calendar", Allow. Add an event starting in 5 minutes with https://meet.google.com/abc-defg-hij in its notes. It appears under "Upcoming recordings" and records from 2 minutes before its start.
6. Open call: join a Google Meet call in Safari or Chrome. Within 15 seconds a notification offers to record it (notifications must be allowed). Only window titles are read.
7. Recent recordings, the file, "Transcribe". Then menu, "Search recordings..." finds a word that was said. "Integrity report (PDF)" writes a PDF next to the recording.
8. Shortcuts: Control-Option-Command-R records or stops, Control-Option-Command-T runs the test. Standard hot key API, no Accessibility permission.
"Open at login" uses SMAppService and stays off until the user ticks it.

PURCHASE
Free download with a 7-day trial, every feature included. Then one non-consumable in-app purchase, "Ipsio lifetime" (US$ 19.99), unlocks the app for life. Please test with a sandbox Apple Account.
1. On a fresh install, a window states the terms, with "Start the 7 days", "Buy now" and "Restore purchase". The menu then shows "Trial: 7 days left", "Buy Ipsio lifetime (<local price>)..." and "Restore purchase".
2. "Buy Ipsio lifetime" opens the App Store payment sheet. After confirming, "THANK YOU" appears and those lines leave the menu.
3. After reinstalling, "Restore purchase" unlocks it again. An account that never bought it gets "NOTHING TO RESTORE".
4. When the trial ends, "Record now" shows "TRIAL ENDED", pointing to Buy and Restore. A recording already running is never stopped.

Thank you.
