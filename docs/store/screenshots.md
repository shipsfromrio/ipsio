# Store screenshots

The Mac App Store takes 1 to 10 screenshots per language, 16:10, at one of
1280x800, 1440x900, 2560x1600 or 2880x1800. They must show the app itself.
Use demo data only: no real meeting, no real name, no real calendar.

## The shots (same list in pt and en: switch the menu's language flag)

1. **The menu while recording** (meeting mode): the red circle, "Recording",
   the level of each track.
2. **Setup window** with every line green.
3. **The consent reminder** popup before a recording.
4. **Upcoming meetings** submenu with two demo events and "Record
   automatically" on.
5. **Recent recordings**, a recording's submenu open: Show in Finder,
   Transcribe, Integrity report (PDF).
6. **A transcript** (`.txt` or `.md`) open next to the recording, with Me and
   Others lines.
7. **Search recordings** window with a hit.
8. **The integrity report** PDF open in Preview.

## How

Make a demo calendar in the Calendar app ("Demo: client meeting", "Demo:
class") and a demo folder of recordings with a demo transcript. Then, for a
menu shot, open the menu and press ⌘⇧5, choose a window or a selection, and
save; for a window, ⌘⇧4 then Space and click it.

Put each shot on a plain 2880x1800 background (it keeps the real pixels, no
scaling of the menu):

```bash
bash docs/store/frame.sh shot.png out/01-menu-en.png
```

Upload in App Store Connect, under the version, Mac screenshots, per
language.
