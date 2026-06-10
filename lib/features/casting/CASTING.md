# Cast to TV — feature notes

## What ships now (updated 2026-05-08)

There are now **three** cast pathways, picked by user intent:

1. **Cast a whole PDF page-by-page** — Chromecast / AirPlay session that
   pulls rendered page PNGs from `/cast/info` + `/cast/page/N.png` (the
   original feature, unchanged). Use the AppBar cast button in the viewer.

2. **Send a file to another Interact Pro device on the same Wi-Fi** —
   peer-to-peer push via `/receive`. Both devices run Interact Pro; the
   receiver auto-opens the file in the right viewer. **This is the
   "share from Samsung phone → Interact Pro on TV" flow.** Triggered
   either from the OS share-sheet handler (`IncomingFileListener`) or
   from a "Send to TV…" action inside the app.

3. **OS-mediated cast** (AirPlay, Quick Share, generic share sheet) —
   the original `SystemCastService` path. Use when the receiver is NOT
   running Interact Pro.

The three pathways share the same mDNS discovery (`bonsoir`) and the
same `LanServer` HTTP server (`shelf` + `shelf_router`). Adding a new
file kind (e.g. `audio`) is a 1-line edit to `ShareKind`.

Two backends behind a `CastService` interface, composed by
`CompositeCastService`:

1. **`SystemCastService`** — OS-mediated path.
   - **iOS / iPadOS:** "AirPlay…" entry → invokes the native
     `AVRoutePickerView` via the `interact_pro/airplay` platform
     channel (`AirPlayPlugin.swift`). User picks an Apple TV / AirPlay 2
     receiver from Apple's own picker.
   - **Any platform:** "Share / Cast…" entry → OS share sheet, exposes
     every Cast-capable target the user has installed.

2. **`ChromecastCastService`** — real Google Cast session.
   - Lists every Chromecast / Android TV / Google TV / Nest Hub on the
     LAN (live, updates as devices come/go).
   - Starts a Cast session with the chosen device.
   - Hands the receiver
     `http://<phone-ip>:<lan-port>/cast/page/{n}.png` so it pulls
     rendered PDF pages from the in-process LAN server.
   - On page change in the viewer, sends a fresh `LoadMedia` so the TV
     auto-advances.

The viewer's AppBar cast button opens a sheet that merges devices from
both backends; tapping a device dispatches to the right service.

## Files

```
lib/features/casting/
├── CASTING.md
├── domain/
│   ├── cast_entities.dart           — CastDevice, CastSession, enums
│   └── cast_service.dart            — abstract interface
├── data/
│   ├── pdf_page_renderer.dart       — pdfx-based page → PNG (share path)
│   ├── local_ip.dart                — Wi-Fi IPv4 lookup for Cast URLs
│   ├── system_cast_service.dart     — AirPlay + share-sheet impl
│   ├── chromecast_cast_service.dart — flutter_chrome_cast impl
│   └── composite_cast_service.dart  — routes by CastProtocol
└── presentation/
    ├── providers/cast_provider.dart — Riverpod (CompositeCastService)
    └── widgets/
        ├── cast_button.dart         — AppBar action
        └── cast_sheet.dart          — bottom-sheet device picker

ios/Runner/
├── AppDelegate.swift                — registers Cast context + AirPlay plugin
├── AirPlayPlugin.swift              — invokes AVRoutePickerView
└── Info.plist                       — NSBonjourServices: googlecast/airplay/raop

android/app/
├── build.gradle.kts                 — play-services-cast-framework dep
└── src/main/
    ├── AndroidManifest.xml          — OPTIONS_PROVIDER_CLASS_NAME meta-data
    └── kotlin/com/interactpak/interactpro/
        └── CastOptionsProvider.kt   — Default Media Receiver wiring
```

## LAN cast endpoints (in `lib/features/lan/data/lan_server.dart`)

| Endpoint | Returns |
|---|---|
| `GET /cast/info` | `{ title, currentPage, totalPages, pageUrlTemplate }` |
| `GET /cast/page/{n}.png` | `image/png` at 2.0× scale |
| `POST /receive?kind=...&name=...` | Receive-side endpoint for the peer-to-peer flow. HMAC-signed body of file bytes; emits an `IncomingShare` event the receiver UI subscribes to. |

## Peer-to-peer share flow (the Samsung-phone → Interact-Pro-TV case)

```
Samsung phone                            Interact Pro on TV
─────────────                            ──────────────────
1. User taps "Share" in Gallery
2. OS share sheet shows "Interact Pro"   (because manifest registers
   alongside WhatsApp etc.                image/* SEND intent-filter)
3. Phone opens Interact Pro;
   IncomingFileListener handles
   the SharedMediaFile
4. Listener offers SendToDeviceSheet
5. User picks "Living Room TV"
6. LanRepository.send(peer, file,
       kind: image, filename: "IMG.jpg")
   → POST http://<tv-ip>:<port>/receive ─────────►  7. _receive validates HMAC,
                                                       writes to incoming/IMG.jpg,
                                                       emits IncomingShare
                                                    8. incomingSharesProvider fires
                                                    9. IncomingFileBootstrap routes
                                                       to image viewer (or PDF,
                                                       video, etc. by ShareKind)
                                                    10. Snackbar: "Received from
                                                        Waseem's iPhone"
```

The phone-side share-sheet entry **only** appears if the manifest's
`SEND` intent-filter declares the right mimeType — already done for
`application/pdf | image/* | video/* | text/plain` as of 2026-05-08.
Add a new mimeType to the manifest *and* a new `ShareKind` value when
you ship a new file class (audio, archive, etc.).

Inert until `LanServer.setActiveCastPdf(...)` is called by
`ChromecastCastService.startMirror`. Cleared on `stopMirror` /
`clearActiveCast`.

## Verifying the package API after `flutter pub get`

`flutter_chrome_cast` is at 0.0.x and its API has churned across
releases. Sanity-check these symbols import cleanly from
`package:flutter_chrome_cast/lib.dart`:

- `GoogleCastDiscoveryManager.instance`
- `GoogleCastSessionManager.instance`
- `GoogleCastRemoteMediaClient.instance`
- `GoogleCastMediaInformation`
- `GoogleCastImageMediaMetadata`
- `CastMediaStreamType.NONE`

If any have moved, fix-ups are confined to four methods at the bottom
of `chromecast_cast_service.dart`:

- `_ensureDiscoveryStarted`
- `_startSession`
- `_loadPage`
- `_endSession`

## Build / native gotchas

### iOS

- `pod install` after `flutter pub get` so `google-cast-sdk` is pulled
  into the Pods workspace.
- iOS 14+ requires the local-network permission prompt — already
  covered by `NSLocalNetworkUsageDescription` in Info.plist.
- AirPlay routing requires that the app's audio session category
  allows route changes. We don't currently customise it; iOS's default
  works for image/video casting. If you ever ship audio playback to
  AirPlay you'll need to set `AVAudioSession.Category` to `.playback`
  in `AppDelegate`.

### Android

- `play-services-cast-framework` ≥ 21 requires `compileSdk 34`, which
  the project's already on (Flutter SDK default).
- The Cast SDK shows a persistent notification while a session is
  active. This is mandatory — don't try to suppress it.
- Doze / battery saver can drop multicast. The existing
  `CHANGE_WIFI_MULTICAST_STATE` permission in the manifest covers
  this, and Bonsoir already acquires the multicast lock on browse.

## Threat model

- LAN cast endpoints are unauthenticated and serve only rendered page
  PNGs of the actively-cast PDF, only over the LAN, only while a cast
  session is live.
- Receivers receive a URL pointing at the device's Wi-Fi IP. Anyone
  else on the same Wi-Fi who guessed the port + path could fetch the
  same image. Threat is low (the receiver is on the LAN by definition,
  and PDFs cast to a TV are usually not secrets) but if needed,
  tighten by adding `X-Cast-Token` to `/cast/*` and embedding the
  token in the URL handed to the receiver.

## Optional: custom HTML receiver app

The Default Media Receiver displays one image at a time, full-screen,
nothing else. For a richer Cast experience (page indicator, "scan QR
to take control", multi-doc playlists) register a custom receiver:

1. Sign up at `cast.google.com/publish` (free; needs the same Google
   account that owns Play Console).
2. Host an HTML5 receiver page (Cloud Run, GitHub Pages, your own VPS).
3. Get an Application ID from the Console.
4. Replace `kGCKDefaultMediaReceiverApplicationID` in
   `AppDelegate.swift` and `DEFAULT_MEDIA_RECEIVER_APPLICATION_ID` in
   `CastOptionsProvider.kt` with the new id.
