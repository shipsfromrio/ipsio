# App Privacy (App Store Connect answers)

## Data collection

**Do you or your third-party partners collect data from this app?** No.

Answer "Data Not Collected". Ipsio has no account, no server, no analytics,
no advertising, no crash-reporting SDK and no third-party code. Nothing the
app records or reads is sent to the developer or to anyone else.

## What the app touches, and where it stays

| What | Why | Where it goes |
|---|---|---|
| Screen and the sound the Mac plays (Screen Recording permission) | the recording itself | a `.mov` in `~/Movies/Ipsio` or a folder the person picks; never leaves the Mac |
| Microphone (meeting mode only) | your voice, in its own track | the same `.mov`; never leaves the Mac. Class mode works without it |
| Calendar (optional, Calendars permission) | to know when a meeting starts and ends, and its name | read on device; only the start, end, title, event identifier and video link of upcoming events are kept, in the app's own folder |
| A private iCal address (optional, pasted by the person) | the same, for a calendar not in the Calendar app | the app downloads that feed directly from the calendar provider the person chose; the address is stored on the Mac, readable only by that user, never sent anywhere else |
| Speech recognition (transcription) | a transcript of a recording | on device only; when macOS lacks the on-device model it downloads it from Apple, and no audio ever leaves the Mac. If on-device recognition is unavailable, the app refuses rather than use a server |
| Window titles and running apps (open-call offer, optional) | to notice an open Zoom, Teams, Meet, Webex or Slack call and offer to record it | read on device every 15 s, only while not recording; nothing is stored or sent. Off with one menu item |
| Transcripts and file names (Search recordings) | to find what was said | read on device from the recordings folder; nothing is written or sent |
| The in-app purchase | unlocking after the 7-day trial | handled by the App Store (StoreKit); the app only reads whether the purchase is valid |

The `.sha256` file next to each recording is a fingerprint computed on the
Mac and written next to the file. It is not uploaded.

## Tracking

**Does this app track users?** No. No App Tracking Transparency prompt is
needed.

## Privacy policy URL (required by App Store Connect)

A page with this text is enough:

> Ipsio collects no data. Recordings, calendar readings and settings stay on
> your Mac. The app has no account and no server. If you paste a private
> calendar address, the app downloads that calendar directly from its
> provider. Purchases are handled by Apple.
