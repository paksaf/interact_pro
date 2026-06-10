# Interact Pro — Three-Issue Diagnosis + Fixes

**Date:** 2026-05-08
**Issues raised:**
1. Email OTP (6-digit code) not arriving in user inboxes
2. App on TV opens in portrait instead of landscape
3. Share-to-TV from Samsung phone shows "Cast" instead of Interact Pro

---

## Issue 1 — Email OTP not reaching users

### Root-cause candidates (in likelihood order)

This is almost certainly **a deliverability problem, not a "send didn't happen" problem**, because the OTP route at `server/pro-api/index.js:96-142` deliberately swallows send failures and returns `200 OK` to the client (so attackers can't probe which emails exist):

```js
if (!send.ok) {
  console.error(`OTP delivery failed for ${contact}: ${send.error}`);
}
res.json({ sentTo: 'email', expiresInSec: ... });
```

So the user sees "code sent", but Resend may have rejected the call OR Gmail/Outlook silently dropped it into spam. The four candidates, in order:

1. **`RESEND_API_KEY` not actually set on the prod VPS.** `.env.local` has it, but `.env.local` is the local-build dev file — `/srv/interact-pro-api/.env` on the VPS is what the running service reads. SSH and `grep RESEND /srv/interact-pro-api/.env` to confirm.

2. **Spam-folder landings (most common cause once #1 is ruled out).** The current `from`/`reply_to` split looks suspicious to spam filters:
   - `from: noreply@send.interactpak.com`
   - `reply_to: interact@paksaf.com`

   Different second-level domains in From vs Reply-To is a classic spam-pattern signal. Either keep both at `@interactpak.com`, or accept the mismatch but make sure `paksaf.com` has its own valid SPF/DKIM (it doesn't pass DMARC alignment for the From otherwise, but it doesn't need to — only From matters for DMARC). Easier: change `OTP_MAIL_REPLY_TO` to `support@interactpak.com`.

3. **Missing DMARC on `interactpak.com`.** Without `_dmarc.interactpak.com` published, Gmail downgrades reputation for new senders. The runbook lists the value to publish: `v=DMARC1; p=quarantine; rua=mailto:dmarc@interactpak.com`.

4. **Resend free-plan rate cap or domain not actually verified.** Free plan is 100 sends/day, 3,000/month. If the OTP route is being hammered (or daily volume crossed during testing), subsequent sends fail. Check the Resend dashboard's "Sends" tab — every successful send appears with status `delivered`/`bounced`/`complained`; failures show with the exact reason.

### Quick triage (10 min, on the VPS)

```bash
ssh root@178.105.73.238

# 1. Confirm the key is loaded by the running process
systemctl show interact-pro-api -p Environment | grep -i resend
# OR if EnvironmentFile= is used:
grep -E "RESEND_API_KEY|OTP_MAIL" /srv/interact-pro-api/.env

# 2. Tail the service logs while you trigger an OTP from the app
journalctl -u interact-pro-api.service -f | grep -iE "otp|resend|email"
# In another terminal / on your phone: tap "Send code" in the app
# Expect to see one of:
#   - nothing at all  → key missing / handler not reached
#   - "OTP delivery failed for ali@x.com: Resend 401: ..." → bad key
#   - "OTP delivery failed for ali@x.com: Resend 422: ..." → unverified from-domain
#   - silent success → email was sent; check Resend dashboard + recipient spam folder

# 3. Direct Resend probe (bypasses the app)
curl -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer $RESEND_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "from": "Interact Pro <noreply@send.interactpak.com>",
    "to": ["YOUR_REAL_EMAIL@gmail.com"],
    "subject": "Resend probe from VPS",
    "text": "If you see this, sending works; the problem is in the app code path."
  }'
# Expect: {"id":"re_..."} on success. Check the Gmail inbox AND spam folder.
```

### Fixes (apply after triage points at one)

- If key missing on VPS: copy from `.env.local` to `/srv/interact-pro-api/.env`, then `systemctl restart interact-pro-api && systemctl status interact-pro-api --no-pager`.
- If Reply-To mismatch is the suspect: edit `server/pro-api/email.js` line 11:
  ```js
  // Was:
  process.env.OTP_MAIL_REPLY_TO ?? 'interact@paksaf.com';
  // Change to:
  process.env.OTP_MAIL_REPLY_TO ?? 'support@interactpak.com';
  ```
  Or (recommended) set `OTP_MAIL_REPLY_TO=support@interactpak.com` in the VPS env so a future code change isn't required.
- If DMARC missing: in Hetzner Cloud DNS for the `interactpak.com` zone, add TXT `_dmarc` with value `v=DMARC1; p=quarantine; rua=mailto:postmaster@interactpak.com`.
- **Optional but high-leverage**: surface the `send.ok=false` case to the user UI via a separate non-blocking notice ("we couldn't send to that address; try a phone number"). Right now the user has zero feedback when delivery silently fails. The security argument for hiding it is weaker for a paid B2B app like Interact Pro than for consumer signup — failed-delivery feedback is a legitimate UX signal, not an enumeration vector.

### Once Comms Hub `/api/comms/send` is wired into Interact Pro

The `email.js` becomes a 3-line wrapper around the hub call (see `_shared/docs/COMMS_HUB_MIGRATION_PLAYBOOK_2026-05-08.md`). The triage steps above stay the same — they just move from the pro-api process to interact-connect.

---

## Issue 2 — TV opens in portrait (FIXED)

### Root cause

`lib/main.dart` lines 16-19 (before the patch) explicitly locked the app to portrait on every Android device:

```dart
await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
  DeviceOrientation.portraitUp,
  DeviceOrientation.portraitDown,
]);
```

On a TV — which is hardware-landscape — Flutter obeys this and renders a 90°-rotated portrait UI in a landscape window, which is what users see as "the app doesn't fit".

### Fix (applied in `lib/main.dart`)

Detect form factor at startup using `PlatformDispatcher.views.first.physicalSize` and pick the orientation lock based on shortest-side:

- **shortest-side ≥ 600 dp** (TVs, tablets in landscape, Chromebooks) → landscape lock
- **everything else** (phones) → portrait lock as before

Why shortest-side and not a `LEANBACK_LAUNCHER` runtime check: the manifest already declares `android.software.leanback` not-required so the same APK installs on phones AND TVs. A runtime size check is the most reliable signal that doesn't need a platform channel.

### Verify

After rebuilding the APK and side-loading on TV:
- App should open in landscape (full-screen, fills the TV).
- On a phone, app still opens in portrait (no regression).
- On a tablet held landscape, app now opens landscape — this is intentional but worth confirming you're OK with it. If you want tablets to stay portrait, change the threshold from `600` to `720` (then only TVs trigger).

### Optional follow-ups

- **Make the dashboard scale-aware.** Even with landscape now correct, your portrait-first layouts (cards stacked vertically) will look sparse on a 1080p TV. Add an `if (MediaQuery.size.shortestSide >= 720)` branch in the home screen to render a 2-column grid.
- **D-pad navigation.** TV remotes use D-pad, not touch. Wrap key clickable widgets in `Focus(autofocus: true, ...)` so the first tile gets focus on launch and arrows move between tiles. The manifest already declares `android.hardware.touchscreen` not-required which is the right thing.

---

## Issue 3 — Samsung share to TV shows "Cast" instead of Interact Pro

### What's actually happening

When you tap **Share** in Samsung Gallery / Files / a browser, Samsung's share sheet shows two layers:
- Top row — "Quick Share" + "Smart View" + connected devices (Samsung's own peer-to-peer / cast layer)
- Below that — apps installed on the phone that registered an `android.intent.action.SEND` filter for that mimeType

The Interact Pro Android manifest (before the patch) only registered `SEND` / `SEND_MULTIPLE` for `application/pdf`. So when the user shares an **image** or **video**, Interact Pro is invisible in the app row, and the only "TV-shaped" option Samsung surfaces is its own Cast / Smart View — that's what the user is seeing.

### Fix part A (applied — manifest change)

Expanded the SEND intent filters in `android/app/src/main/AndroidManifest.xml` to cover the formats users actually share:

```xml
<intent-filter>
    <action android:name="android.intent.action.SEND" />
    <category android:name="android.intent.category.DEFAULT" />
    <data android:mimeType="application/pdf" />
    <data android:mimeType="image/*" />
    <data android:mimeType="video/*" />
    <data android:mimeType="text/plain" />
</intent-filter>
<intent-filter>
    <action android:name="android.intent.action.SEND_MULTIPLE" />
    <category android:name="android.intent.category.DEFAULT" />
    <data android:mimeType="application/pdf" />
    <data android:mimeType="image/*" />
    <data android:mimeType="video/*" />
</intent-filter>
```

Rebuild + install the phone APK. **After this**, sharing a photo from Samsung Gallery will show Interact Pro in the app row alongside WhatsApp, Drive, etc.

### Fix part B (still TODO — the actual phone-to-TV push)

After the user picks Interact Pro from the share sheet, the file lands in the phone's Interact Pro app via `receive_sharing_intent`. **You still need code to push it from the phone-side app to the TV-side app.** Three ways, ordered by build cost:

#### Option 1 — Lean on the existing Drive sync (easiest, ships in a day)

The app already has `features/drive_sync/` (you can see `sync_worker.dart` imported in `main.dart`). The flow:
1. Share → phone app stores the file in a special "Cast Inbox" folder in Drive
2. TV app polls / watches that folder via `WorkManager` (already wired)
3. New file appears → TV displays it

**Pros:** zero new infrastructure, works across networks (phone on 4G + TV on home WiFi)
**Cons:** 5-30 second latency, requires both devices signed into the same Drive

#### Option 2 — LAN push via mDNS (the "real" cast experience, ~3-5 days)

Infrastructure is half-done — the manifest already declares `CHANGE_WIFI_MULTICAST_STATE` and references `LanDiscoveryService` for mDNS browsing. To finish:
1. **TV side:** start a small HTTP server (Flutter's `shelf` package) on a random port. Advertise it via mDNS as `_interactpro-cast._tcp.local`. Show the TV's display name in `LanDiscoveryService` discoveries.
2. **Phone side (share-target screen):** browse mDNS for `_interactpro-cast._tcp.local` — list the discovered TVs as "Send to TV" tiles. User taps a tile → POST the file to that TV's HTTP endpoint.
3. **TV side (receive):** accept the POST, write to disk, broadcast a `castReceiveProvider` Riverpod event so the current screen renders the file.

**Pros:** sub-second, no internet, no Drive dependency, full feature control
**Cons:** real engineering work; needs to handle TV being on a different VLAN than phone (Smart TVs often are)

#### Option 3 — Google Cast SDK (already partially wired)

The manifest references `CastOptionsProvider` (line 100). If that class actually exists in the Kotlin/Java sources, you're using the Default Media Receiver to stream image URLs at the TV. Two things to check:
1. Does `com.interactpak.interactpro.CastOptionsProvider` exist in `android/app/src/main/kotlin/...`? If not, Cast SDK isn't actually working — strip the meta-data so it doesn't crash on launch.
2. If it does exist, the share flow can hand the local image to a Cast `MediaInfo` and stream it to the TV. **But** this only works for media-type content (images/videos) and requires the TV to have a Chromecast built-in OR to be running Interact Pro and registered as a Cast receiver. The latter requires a registered Receiver app at <https://cast.google.com/publish/> ($5 one-time fee).

**Recommended path:** Option 1 first (ship in a day, satisfies 80% of the use case), then Option 2 over a longer cycle. Option 3 only if you want to play nicely with non-Interact-Pro TVs (Chromecast, AppleTV-with-AirPlay, etc.) — that's a bigger product decision.

### Verify Part A right now

After rebuilding + installing the patched APK on a Samsung phone:

```
1. Open Samsung Gallery
2. Pick a photo → tap Share
3. Scroll the bottom app row — Interact Pro should now appear
4. Tap it → photo opens in Interact Pro's "received share" screen
   (whatever your existing receive_sharing_intent handler renders)
```

If Interact Pro still doesn't appear:
- Force-stop the app, then re-share (Samsung caches the share-target list aggressively)
- `adb shell pm dump com.interactpak.interactpro | grep -A5 mimeType` — confirm the new filters are in the installed manifest

---

## Files changed in this commit

- `lib/main.dart` — landscape-on-TV detection + orientation switch
- `android/app/src/main/AndroidManifest.xml` — SEND intent-filter expanded to image/video/text
- `INTERACT_PRO_FIXES_2026-05-08.md` (this file)

## Files NOT changed (recommendations only)

- `server/pro-api/email.js` — change `OTP_MAIL_REPLY_TO` default if you want; or set the env var. The hub-routed migration will rework this file anyway.
- `server/pro-api/index.js` — consider surfacing `send.ok=false` to the client UI as a non-blocking notice. Decide based on your security posture.
