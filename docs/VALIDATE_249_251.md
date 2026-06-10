# Validation Guide — #249 (karaoke) & #251 (OCR accuracy)

Both bugs were downstream of #248 (AI secret missing from APK). The
last rebuild + reinstall (2026-05-20) baked the secret correctly via
`--dart-define-from-file=dart_defines.json`. This doc is the 5-minute
test plan to confirm both regressions are gone.

## Pre-flight

Both devices should be on the APK that has the AI secret baked in:

```bash
adb -s R68T304FX1F shell dumpsys package com.interactpak.interact_pro | grep versionName
adb -s 192.168.100.4:5555 shell dumpsys package com.interactpak.interact_pro | grep versionName
```

Both should report the same `versionName` (e.g. `2.0.3+2010`).

## Test #249 — Karaoke highlighting

The karaoke strip uses `flutter_tts` word-level callbacks on Android
and a server-driven position estimate on the Bravia (Pro #157). It
requires:
- An active TTS voice (system or Piper)
- A non-empty AI secret (Piper backend is the cloud path)
- An open PDF in BookViewer

**Phone test (system voice path):**

1. Open any PDF in the library — pick one with plain prose text (not
   image-heavy). Lonely Planet pages or a textbook chapter work well.
2. Tap the read-aloud icon (speaker, top-right of BookViewer).
3. Wait for the first sentence to start.

**Expected:** the current word should glow with the Karaoke strip's
cyan highlight, sliding word-by-word in sync with the spoken audio.
The strip lives at the bottom of the page above the page-flip slider.

**If broken:**
- No highlight at all → `KaraokeStrip` widget didn't mount. Check
  the BookViewer Stack for the karaoke strip layer.
- Highlight stuck on word 1 → `TtsProgress` stream isn't emitting.
  Check `system_tts.dart` for the `onWordBoundary` callback wiring.
- Highlight runs ahead of audio → position estimate drift on the
  remote/Piper path. Acceptable up to ~200ms; beyond that, log a
  fresh bug with the title + voice name.

**Bravia test (Piper voice path):**

1. Pick Piper voice "Amy" in Settings → Reading → Voice.
2. Open the same PDF, tap read-aloud.

**Expected:** Same karaoke behaviour. Piper streams MP3 chunks, so
there's a startup delay of 200-400 ms vs the phone's instant start.

## Test #251 — OCR accuracy

OCR runs through:
1. Local Tesseract (always) — produces the baseline output
2. Surya backend at `https://pro.interactpak.com/api/ocr/advanced`
   when Settings → Reading → "Advanced OCR backend" is ON + AI
   secret is present

**Test pages:**

| Source         | Page                                  | Why it's a useful test |
|----------------|---------------------------------------|------------------------|
| Docker whitepaper | "Volcanoes" diagram caption page     | Phrase that used to come back as "Vo Icanoes" with Tesseract-only |
| Any textbook   | Two-column page with footnotes         | Layout-aware OCR is the killer feature |
| Receipt photo  | Phone-camera capture of any printed receipt | Confidence handling on noisy input |

**Procedure:**

1. Open one of the test pages.
2. Tap the "Extract text" button (page menu → Extract / Copy text).
3. Wait for the result snackbar / dialog.

**Expected on the phone (AI secret baked in):**
- "Volcanoes" comes back cleanly — no "Vo Icanoes" garbage
- Two-column layout preserves reading order (left column finished
  before right column starts), not interleaved
- Snackbar shows engine name "Surya" if the advanced toggle is on
- Confidence appears in the share-sheet > 0.85 typical

**Expected on the Bravia:**
- Same outputs. The Bravia talks to the same Surya backend, so
  parity should be tight.

**If OCR falls back to Tesseract:**
- Snackbar will say "Tesseract" or "fallback" — open the app's
  developer log (Settings → Developer → Logs) and grep for
  "ocr.engine=tesseract reason=..."
- Most common cause now: the bearer-secret header missing. Run
  `bash scripts/bake-ai-secret.sh --print` and confirm the JSON
  has the 64-byte value baked in.

## What to do if both fail

The most likely cause is the APK got built without
`--dart-define-from-file=dart_defines.json`. Rebuild:

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro
bash scripts/bake-ai-secret.sh       # confirms VPS-side secret is fresh
flutter build apk --release --dart-define-from-file=dart_defines.json
adb -s R68T304FX1F install -r build/app/outputs/flutter-apk/app-release.apk
adb -s 192.168.100.4:5555 install -r build/app/outputs/flutter-apk/app-release.apk
```

(That's the exact command from the last validation pass that worked.)
