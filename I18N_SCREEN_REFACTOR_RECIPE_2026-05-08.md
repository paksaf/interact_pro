# i18n Per-Screen Refactor Recipe

**Date:** 2026-05-08
**Reference implementation:** [`lib/features/auth/presentation/screens/login_screen.dart`](lib/features/auth/presentation/screens/login_screen.dart)

This is the playbook for converting one screen at a time from hard-coded English strings to AppLocalizations-driven strings. The login screen is the worked example — when you (or an agent / contractor) take on the next screen, follow these steps in order.

---

## Why one-screen-at-a-time

Doing the whole app in one PR is ~3-5 days of focused work. Doing it screen-by-screen means each PR is ~2 hours, can be reviewed independently, and the rest of the app keeps working with English literals during the migration. Pick the screens by traffic — Home, Viewer, Settings, Login, Paywall — and let the long-tail (AR Measuring, Code Scanner History) wait until they're touched for other reasons.

---

## The recipe (5 steps, ~2 hours per screen)

### Step 1 — Audit the strings

Find every hard-coded English string in the screen file:

```bash
# From the screen's directory:
grep -nE "(Text|tooltip:|labelText:|hintText:|content:\s*Text|content:\s*const Text|title:\s*const? Text|label:\s*Text|label:\s*const Text|child:\s*const? Text|SnackBar.*Text)" \
  login_screen.dart \
  | grep -v "// " | grep -v "AppLocalizations"
```

Make a list. For the login screen, this turned up 14 strings:
- "Welcome to Interact Pro"
- "Sign in to save your library to the cloud, sync across devices, and unlock Pro features."
- "Email" (tab label)
- "Phone" (tab label)
- "Email address" (input label)
- "Phone number (with country code)" (input label)
- "+92 300 1234567" (input hint)
- "Enter an email or phone number" (error)
- "Sending…" (button, busy state)
- "Send code" (button)
- "Continue without an account" (text button)
- "Free 7-day trial. Pro unlocks AI handwriting, vision LLM, cloud sync, and extra storage."
- "Already signed in" (banner header — added today)
- "Signed out — sign in with a different account" (snackbar — added today)

Plus button labels reused from a shared set: "Sign out", "Home", "Cancel".

### Step 2 — Pick keys, add to ARB

Convention from the existing `app_en.arb`:
- Group keys by feature prefix (`login*`, `home*`, `viewer*`, `settings*`)
- `action*` for verbs reused across screens (Cancel, Save, Sign out)
- `tooltip*` for hover/long-press text
- `nav*` for bottom nav / sidebar labels
- `error*` for validation messages

For the login screen, the new keys:

```json
"actionSignOut": "Sign out",
"actionHome": "Home",
"actionSendCode": "Send code",
"actionSending": "Sending…",
"actionContinueWithoutAccount": "Continue without an account",

"loginAlreadySignedIn": "Already signed in",
"loginSignedOutNotice": "Signed out — sign in with a different account",
"loginWelcome": "Welcome to Interact Pro",
"loginWelcomeBlurb": "Sign in to save your library to the cloud, sync across devices, and unlock Pro features.",
"loginTabEmail": "Email",
"loginTabPhone": "Phone",
"loginEmailLabel": "Email address",
"loginPhoneLabel": "Phone number (with country code)",
"loginPhoneHint": "+92 300 1234567",
"loginErrorEmptyContact": "Enter an email or phone number",
"loginTrialBlurb": "Free 7-day trial. Pro unlocks AI handwriting, vision LLM, cloud sync, and extra storage."
```

If a string is reused across multiple screens (e.g. "Cancel"), put it under the `action*` namespace so other screens can reuse the same key.

Add the keys to BOTH `lib/l10n/app_en.arb` AND `lib/l10n/app_ur.arb`. The English values are usually self-evident from the original literals; the Urdu values are translations.

### Step 3 — Translate to Urdu

Don't leave Urdu values as the English strings — Flutter will use them verbatim and you'll have an English-rendered Urdu locale (worse than just falling back to English). Either:

- **Translate yourself** if you read/write Urdu (Waseem does — I asked an Urdu-aware agent and these are the values I added; review and adjust)
- **Get a translator pass** before merging (cheaper than you think — a quick Fiverr translator does ~50 strings in an hour for $10-20)
- **Use a placeholder** (`"loginWelcome": "[ur] Welcome to Interact Pro"`) and a translator goes through the file later — this leaves the app broken in Urdu but at least it's obvious what hasn't been done

For the login screen, all 14 strings are translated in `app_ur.arb`. Standard / formal Urdu, written by an Urdu-aware agent. A native speaker should review before App Store release.

### Step 4 — Regenerate the typed accessors

After editing the ARB files:

```bash
cd /Users/muzafar/Documents/INTERACT/interact_pro
flutter gen-l10n
# OR if you use the auto-run on pub get:
flutter pub get
```

This rewrites `lib/l10n/app_localizations.dart`, `lib/l10n/app_localizations_en.dart`, `lib/l10n/app_localizations_ur.dart` so every key gets a typed Dart getter.

If `flutter gen-l10n` fails with a JSON parse error, you have a syntax error in one of the ARB files (missing comma, unbalanced quote, smart quote from a copy-paste). The error message points at the line.

### Step 5 — Wire the screen

Top of the file:

```dart
import '../../../../l10n/app_localizations.dart';
```

Inside `build(context)`:

```dart
final l = AppLocalizations.of(context);
```

Then replace every literal:

```dart
// Before:
const Text('Welcome to Interact Pro')

// After:
Text(l.loginWelcome)
```

A common gotcha: `const` widgets can't take a runtime-resolved string. Drop the `const` from the widget when you swap in the AppLocalizations getter:

```dart
// Before:
const Text('Email', style: TextStyle(fontSize: 14))

// After:
Text(l.loginTabEmail, style: const TextStyle(fontSize: 14))
//                    ↑ const moves down to the immutable bit
```

State-class methods (like `_signOutAndStay()`) need access to `context` to call `AppLocalizations.of(context)`. In `ConsumerState` / `State` that's just `this.context`:

```dart
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(content: Text(AppLocalizations.of(context).loginSignedOutNotice)),
);
```

### Step 6 — Smoke test

Build + run:
```bash
flutter run --release
# Or attach to a connected device:
flutter run -d <device-id>
```

Manual test:
1. Open the screen in **English** — every string renders correctly
2. Settings → Language → **Urdu** — every string is now in Urdu, layout is RTL, no English leaks through
3. Settings → Language → **Follow system language** — if your device is `en` you see English; if it's `ur` you see Urdu

If a string is still English after switching to Urdu, that one didn't get refactored — grep for it in the file and continue from Step 5.

---

## Anti-patterns to avoid

- **Don't use string interpolation in literals** — `'Hello $name'` won't translate. Use ICU placeholders in ARB:
  ```json
  "greeting": "Hello {name}",
  "@greeting": { "placeholders": { "name": { "type": "String" } } }
  ```
  Then in Dart: `l.greeting('Waseem')`. (Generated as a method, not a getter.)
- **Don't translate user-generated content** — file names, document titles, notes the user typed. Those are data, not UI labels.
- **Don't translate brand names** — "Interact Pro" stays "Interact Pro" (or the Urdu transliteration "انٹریکٹ پرو", which is what's used today). "DeepSeek", "ML Kit", "Resend" — leave English.
- **Don't translate keyboard shortcuts** — `Ctrl+S` stays `Ctrl+S` regardless of locale.
- **Don't forget RTL-specific layout fixes** — sometimes a screen looks broken in Urdu because an `EdgeInsets.only(left: 16)` should be `EdgeInsets.only(start: 16)` (the directional version). Touch up as you find them, not pre-emptively.

---

## Recommended next screens (in order of impact)

| Screen | File | Approx string count | Why this order |
|---|---|---|---|
| **Home** | `lib/features/home/presentation/screens/home_screen.dart` | ~25 | Most-visited screen; sets the tone |
| **Settings** | `lib/features/settings/presentation/screens/settings_screen.dart` | ~40 | Includes the language picker itself — ironic to have it in English |
| **Paywall** | `lib/features/pro/presentation/screens/paywall_screen.dart` | ~15 | Conversion-critical; where the new "request access" email path lives |
| **Viewer** | `lib/features/viewer/presentation/screens/viewer_screen.dart` | ~30 | Where users spend the most time; lots of menu items |
| **Scanner** | `lib/features/scanner/presentation/screens/scanner_screen.dart` | ~20 | Filter labels, "Save N-page PDF" string we added today |
| **Handwriting** | `lib/features/handwriting/presentation/screens/handwriting_screen.dart` | ~30 | New error / download messages we added today |

After these six (~2 hours each = 12 hours total), the app will feel substantially Urdu when set to Urdu. The remaining long-tail is fine to handle as it's touched.

---

## Sources

- Reference impl: [`lib/features/auth/presentation/screens/login_screen.dart`](lib/features/auth/presentation/screens/login_screen.dart)
- ARB files: [`lib/l10n/app_en.arb`](lib/l10n/app_en.arb), [`lib/l10n/app_ur.arb`](lib/l10n/app_ur.arb)
- Generated: [`lib/l10n/app_localizations.dart`](lib/l10n/app_localizations.dart) (do not hand-edit; regenerate via `flutter gen-l10n`)
- Locale plumbing: [`lib/core/i18n/locale_provider.dart`](lib/core/i18n/locale_provider.dart)
- Companion doc: [`AUTH_AND_I18N_TRIAGE_2026-05-08.md`](AUTH_AND_I18N_TRIAGE_2026-05-08.md) — context on why the gap existed
