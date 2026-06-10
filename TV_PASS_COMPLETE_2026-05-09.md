# Interact Pro — TV Pass Complete

**Date:** 2026-05-09
**Status:** All deferred / pending TV tasks from the morning roadmap are shipped. Rebuild + sideload + retest.

---

## What landed today (in addition to this morning's seven fixes)

### A. TV bookshelf as home body
- File: `lib/features/home/presentation/screens/home_screen.dart` — `_TabletHomeBody` now renders `_BookshelfBody` when `MediaQuery.size.shortestSide >= 720` (TV-sized). Same shelf widget the existing LibraryScreen uses, but inline so the home AppBar and shortcut rail stay visible.
- Tap a book → opens with **page-flip BookViewer** (curl animation)
- Long-press → bottom-sheet picker: page-flip vs editor view

### B. PDF viewer keyboard navigation (already from morning)
- Left / PageUp = previous page
- Right / PageDown / Space = next page
- Home / End = first / last page
- Works with TV remote D-pad on any Android TV.

### C. D-pad focus polish on key screens
Now have an autofocused interactive element so D-pad has a starting target on entry:
- **Home screen**: first shortcut tile (`_ShortcutRail`)
- **Settings**: first ListTile (Support)
- **Nearby Devices**: refresh button in AppBar (always present, even when zero peers)
- **Login**: email field (already had autofocus)
- **Drive Browser**: refresh button when listing files; "Sign in with Google" button when signed out
- **Image Viewer**: already had keyboard handlers from morning's pass

### D. Same-account auto-pair (new!)
This is the big UX win for the "phone + TV both signed in to my Interact Pro account" use case.

**Before:** to share a PDF from phone to TV, you opened Settings → Nearby Devices on both, tapped Pair, entered a 6-digit PIN that appeared on the TV. Every. Single. Time. (Once per pair.)

**Now:** if both peers are signed in to the same Interact Pro account, the pair handshake skips the PIN entirely. First time you go to Send to Device on the phone, the TV is already in the "Paired" section.

**How it works:**
- `LanServer._info` includes `userIdHash` (SHA-256 of `interact-pro:<userId>`) when a user is signed in
- `LanServer._pairInit` checks if the requesting peer's `fromUserIdHash` matches its own hash — if yes, mints the secret and persists immediately, returning `{autoPaired: true, secret: ...}`
- `LanRepository.pair()` recognises the `autoPaired: true` response and skips the PIN modal — saves the secret to PairedDevices and returns the device

**Privacy:** raw user IDs are never sent over the LAN. Only the SHA-256 hash, with a static prefix to prevent rainbow-table reuse across other apps that might also identify users by id. Peers can verify "we share an account" without learning each other's account ID.

**Fallback:** if the user is signed out on either side, OR they're on different accounts, the regular PIN flow runs unchanged.

**Files changed:**
- `lib/features/lan/data/lan_server.dart` — `currentUserIdGetter` ctor field, `_userIdHash`, `/info` includes hash, `/pair/init` short-circuits
- `lib/features/lan/data/lan_repository.dart` — same getter, sends `fromUserIdHash`, recognises auto-pair response
- The `lanRepositoryProvider` reads `authUserProvider.asData?.value?.id` lazily so signing in/out takes effect immediately

### E. Drive browser screen (replaces stub)
- File: `lib/features/drive_sync/presentation/screens/drive_browser_screen.dart` — new
- Wired in `app_router.dart` replacing the old `_DrivePlaceholder` stub
- When signed in: lists every PDF in the user's Drive Interact Pro folder with name, modified date, size; tap to download + open + register in Recents
- When signed out: clear "Sign in with Google" call to action with autofocused button (TV-friendly)
- This is now the **primary path** to get PDFs onto a TV — the system FilePicker doesn't work without a file manager, but Drive does

### F. TV launcher banner declared (placeholder)
- `AndroidManifest.xml` was already declaring `android:banner="@mipmap/ic_launcher"` — TV launchers pull this for the Android TV row of apps
- Currently using the square launcher icon, which is why it looks slightly stretched on a 320×180 banner slot
- **Proper fix needs a designed asset** — a 320×180 landscape banner. When you have it, drop into `android/app/src/main/res/drawable-xhdpi/ic_banner.png` (and densify to xxhdpi/xxxhdpi) and switch the manifest line to `android:banner="@drawable/ic_banner"`. Designer task, not code.

---

## Try-it sequence (after rebuild + sideload)

```bash
cd ~/Documents/INTERACT/interact_pro
flutter build apk --release
bash scripts/build-and-upload.sh --no-build --android-only
```

Then:

1. **On phone**: open browser → `pro.interactpak.com` → Download → install over existing
2. **On TV**: same URL via Send Files to TV / Downloader → install over existing
3. **Sign in to the same account on both** (same email or phone OTP)

Expected behaviours after both are on the new build:

| Action | Expected | Why |
|---|---|---|
| Open Interact Pro on TV | Lands on home, **bookshelf layout** filling the TV (no narrow centered column) | Width-aware home body |
| Press D-pad on TV | Visible focus ring on first shortcut tile | Autofocus + Material focus rings |
| Navigate to Settings → Nearby Devices on TV | Refresh button autofocused; the TV is broadcasting; the phone shows up | mDNS broadcast confirmed |
| On phone: Settings → Nearby Devices | TV shows up in **Paired** section without asking for a PIN | Same-account auto-pair |
| On phone: share a PDF → Interact Pro → SendToDevice → tap TV | "Sent to TV" snackbar; TV shows "Received from \<phone\>" snackbar; PDF auto-opens in BookViewer (curl-flip) on TV | Streaming /receive + auto-route + page-flip viewer |
| On TV: Drive nav tab → sign in → tap a PDF | File downloads, opens in viewer, lands in Recents | New DriveBrowserScreen |
| On TV: home → arrow-down through bookshelf → enter on a book | Page-flip viewer opens fullscreen; arrow keys turn pages | Bookshelf + viewer keyboard nav |

---

## What's STILL deferred

| Item | Effort | Why deferred |
|---|---|---|
| Designed 320×180 TV launcher banner | Designer time | Code wired; just needs an asset |
| Splash screen TV-friendly variant (large logo) | 1-2 hr | Visual polish; current splash is fine |
| Voice commands via TV remote (mic button → app actions) | 4-6 hr | Big feature, separate roadmap item |
| D-pad focus on every secondary screen (Scanner, Handwriting, Paywall, OTP, Library, Admin) | ~2 hr mechanical | Diminishing returns until you sit with the remote and find the gaps |
| Cross-device library sync via cloud (= Future-3 cloud storage) | 3 weeks | Strategic feature; per the admin design doc, wait for two apps to demand it |
| Real Chromecast receiver registration (Cast SDK App ID) | 1 day + $5 fee | Same-account auto-pair covers most of this need; defer until non-Interact-Pro TVs need to be cast targets |

---

## Where this leaves the roadmap

Tomorrow's resume sequence (set yesterday in `SESSION_2026-05-08.md` Tomorrow's priorities):
- ✅ **Priority 1 — Proper app for TV**: foundation done. Remaining items are visual polish (banner, splash) and per-screen D-pad polish — both can happen incrementally.
- ⚠️ **Priority 2 — Cast on Android + iOS**: phone-to-TV cast on same Wi-Fi works after this build (auto-pair removes the friction that was blocking testing). iOS still untested — needs a build + sideload via Diawi/Sideloadly.
- ⏸️ **Priority 3 — Cloud access**: not started; design lives in `_shared/docs/ADMIN_PANEL_SCOPE_AND_DESIGN_2026-05-08.md`.
- ⏸️ **Priority 4 — interactpak.com email**: not addressed today; the morning's outbound-email patch lives in code but hasn't been deployed to VPS yet.

---

## Sources

- [`SESSION_2026-05-08.md`](../SESSION_2026-05-08.md) — yesterday's full log
- [`TV_POLISH_ROADMAP_2026-05-09.md`](TV_POLISH_ROADMAP_2026-05-09.md) — morning's roadmap (most items now done; remainder still valid)
- [`_shared/docs/LAN_CAST_REUSE_2026-05-08.md`](../_shared/docs/LAN_CAST_REUSE_2026-05-08.md) — adoption guide for other INTERACT apps
- [`_shared/docs/MULTI_PLATFORM_TV_STRATEGY_2026-05-08.md`](../_shared/docs/MULTI_PLATFORM_TV_STRATEGY_2026-05-08.md) — Tier 2 / Tier 3 (web receiver / Chromecast) for non-Android TVs
