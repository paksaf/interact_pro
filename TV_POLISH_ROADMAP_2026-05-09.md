# Interact Pro TV — Polish Roadmap

**Date:** 2026-05-09
**What this covers:** the TV-experience improvements that are NOT in today's "TV pass" patch. Today's patch addressed the seven critical bugs (orientation, narrow column, missing Settings, vanishing recents, file-picker dead-end, Drive empty-state, viewer D-pad). This doc captures the next tier — visual polish, voice control, page-flip animations — that need their own dedicated time.

---

## Today's TV pass (already shipped)

| Issue | Fix | File |
|---|---|---|
| Home rendered in narrow phone column on TV | `WindowSize.of()` now considers longest-side ≥ 1200dp as "expanded" — flips home to the existing tablet/TV layout with side rail | `lib/core/layout/responsive.dart` |
| Settings unreachable (10 AppBar icons cropped) | Added Settings as 5th bottom-nav tab on tablet/TV form factors | `lib/core/routing/app_router.dart` |
| No D-pad focus ring | Added `autofocus: true` to first shortcut tile so D-pad has a starting target | `lib/features/home/presentation/screens/home_screen.dart` |
| PDF vanishes from recents | `listLocal()` no longer auto-deletes rows when files are missing — keeps the entry, attempts same-basename rescue first, otherwise renders the row so user can tap-to-relocate | `lib/features/viewer/data/repositories/pdf_repository_impl.dart` |
| "No app to handle this" on Import | Wrapped `FilePicker.pickFiles` in try/catch; on error, opens a sheet pointing at Drive / Scan / phone-share | `lib/features/home/presentation/screens/home_screen.dart` |
| Empty state says "Tap Import PDF" with no alternatives | Empty state now offers Drive + Scan buttons plus "Import PDF may not work on TVs" hint | `lib/features/home/presentation/screens/home_screen.dart` |
| PDF viewer can't advance pages without touch | `Focus(autofocus: true, onKeyEvent: ...)` wraps the viewer body — Left/PageUp = previous, Right/PageDown/Space = next, Home/End = first/last | `lib/features/viewer/presentation/screens/viewer_screen.dart` |

## Tier 2 polish (this doc — pick when ready)

### A. Higher-resolution TV launcher icon

**Problem:** the launcher icon looks blurry on a 1080p TV. It's rendered from the same `assets/icon/icon.png` (1024×1024) used for phones — fine for a 5-inch screen, soft on a 55-inch TV.

**Fix:** Android TV uses a separate "banner" asset for the leanback launcher (320×180, landscape orientation). Generate one + add to manifest:

```xml
<application
    android:label="Interact Pro"
    android:icon="@mipmap/ic_launcher"
    android:banner="@mipmap/ic_banner"   <!-- NEW: TV banner -->
    ...>
```

Then add `mipmap-xhdpi/ic_banner.png` (320×180) and densify to xxhdpi/xxxhdpi. The banner is what appears in the Android TV row of apps.

For the regular launcher icon at higher density: regenerate via `dart run flutter_launcher_icons` after replacing `assets/icon/icon.png` with a higher-resolution source (2048×2048 minimum). Already wired in pubspec under `flutter_launcher_icons:`.

**Effort:** 1-2 hours. Need a designer-grade icon source + a 320×180 banner artwork.

### B. TV-friendly splash screen

**Problem:** current splash is the centered icon on dark green from `flutter_native_splash`. Looks tiny on a TV — the icon occupies ~5% of the screen.

**Fix:** `flutter_native_splash` config supports per-android-mode variants. In pubspec under `flutter_native_splash:`, add:

```yaml
flutter_native_splash:
  color: "#0A2A1F"
  image: "assets/icon/icon-fg.png"
  android: true
  ios: true
  # Android TV / leanback variant — bigger asset, optional centered title
  android_12:
    image: "assets/icon/icon-fg.png"
    icon_background_color: "#0A2A1F"
```

For TV specifically: replace the splash widget at `lib/core/splash/animated_splash.dart` with a layout that uses `MediaQuery.size.shortestSide >= 720` to render a larger logo + brand wordmark. The animated splash is already a Flutter widget so this is a layout edit, not native config.

**Effort:** 1-2 hours.

### C. Voice commands via TV remote

**Problem:** TV remotes have a microphone button. Today it goes to Google Assistant / Alexa, not Interact Pro.

**Fix path:**
- The app already depends on `speech_to_text: ^7.0.0` (in pubspec for the voice dictation feature).
- On Android TV the system mic button fires an `Intent.ACTION_VOICE_COMMAND` or `Intent.ACTION_SEARCH_LONG_PRESS` depending on the launcher.
- Register an intent filter in `AndroidManifest.xml` so the app receives voice events when it's the foreground activity.
- Inside Flutter, hook `SpeechToText.listen()` to the native intent via a small platform channel (`MethodChannel`), then route the recognised text to commands like:
  - "open invoice" → search recents for "invoice"
  - "next page" → `_pdfController.nextPage()`
  - "scan a page" → push `/scanner`
  - "go to settings" → push `/settings`

**Effort:** 4-6 hours. Includes the platform channel + a small command parser. Keep the parser dumb (string match a list of phrases) until usage justifies more.

### D. Bookshelf as TV home (cards in horizontal rows)

**Problem:** today's home tablet layout is "side rail + recents list". A 10-foot couch viewer wants a Netflix-style horizontal carousel of "Continue reading" / "Library" rows.

**The good news:** `lib/features/library/presentation/screens/library_screen.dart` already implements a horizontal-shelf layout (the existing `BookCard` + `ShelfRow` widgets). It's reachable via the AppBar "Library" icon today.

**Fix:** when `WindowSize.of(context).isExpanded` AND form factor smells like TV (shortest-side ≥ 720), make the home `body:` render the `LibraryScreen` content inline instead of the recents+rail layout. ~30 min of routing.

**Effort:** 30 min of UI swap, plus design time deciding what shows in the shelves (Recent / Library / Scanned / Annotated / etc).

### E. Page-flip animation on TV viewer

**Problem:** the PDF viewer uses Syncfusion's default scroll-to-next-page. On a TV that "feels" like a document, not a book.

**The good news:** `lib/features/book_viewer/presentation/screens/book_viewer_screen.dart` + `widgets/page_flip.dart` already implement a curl-and-flip animation.

**Fix:** when on TV form factor, route opens via `AppRoutes.bookViewer` instead of `AppRoutes.viewer`. Or add a "Book mode" toggle to the viewer's AppBar overflow that switches between linear scroll and curl-flip.

**Effort:** 30 min routing change. Page flip animation already works with arrow keys (we wired keyboard nav today; same controller).

### F. D-pad focus polish across non-home screens

**What we did today:** added `autofocus: true` to the first shortcut tile on home + the viewer body. That gives D-pad a starting target on those two screens.

**What's still missing:** every other screen (Settings, Login, OTP, Library, Scanner, Image Viewer, Handwriting, Paywall, Nearby Devices, Admin) needs the same first-element autofocus + a logical traversal order. Material widgets (`FilledButton`, `IconButton`, `ListTile`) DO render focus rings when focused — but only if focus actually reaches them.

**Fix pattern (apply per screen):**
```dart
// On the FIRST interactive widget of each screen:
ListTile(autofocus: true, ...)
// Or for a button:
FilledButton(autofocus: true, ...)
// Or wrap a non-focusable widget:
Focus(autofocus: true, child: ...)
```

**Effort:** 15 min per screen × 8 screens = ~2 hours. Best done as a batch pass once you have a remote in hand to validate.

---

## Recommended order

If you have one weekend evening:

1. **D + E** (1 hour total) — instant TV-feel upgrade, no new assets needed. Routes existing widgets at TV form factor.
2. **F** (2 hours) — D-pad polish across screens. Tedious but mechanical.
3. **A** (1-2 hours, needs a designer or a public-domain banner image) — visible polish.

If you have a full day:

1. **D + E + F** as above (~3-4 hours)
2. **C** (4-6 hours) — voice commands. Highest UX win on a TV; remote typing is painful.

If you have a week:

Pick one screen at a time and do A+B+D+E+F properly per screen, including TV-specific layouts where appropriate. Before submitting to Play Store as a TV app you'd want this complete pass anyway.

---

## What we're NOT doing (and why)

- **Separate TV-only Flutter app.** Single APK works fine; one codebase is cheaper to maintain.
- **Native Android TV (Kotlin) app.** Same — Flutter's TV story is mature enough now (Q2 2026), no need to fork.
- **Custom Cast receiver app for TV side.** The existing LAN cast works peer-to-peer; building a Cast SDK receiver is a separate path that only matters for non-Interact-Pro receiving devices (covered in `_shared/docs/MULTI_PLATFORM_TV_STRATEGY_2026-05-08.md` Tier 2).

---

## Sources

- Today's TV pass: see [`SESSION_2026-05-09.md`](../SESSION_2026-05-09.md) (when written) and the file-by-file changes above
- Companion: [`_shared/docs/MULTI_PLATFORM_TV_STRATEGY_2026-05-08.md`](../_shared/docs/MULTI_PLATFORM_TV_STRATEGY_2026-05-08.md) — three-tier coverage strategy for non-Android TVs
