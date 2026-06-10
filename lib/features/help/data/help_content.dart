// SPDX-License-Identifier: AGPL-3.0
//
// Structured help content for the Help screen + onboarding slides.
// One source of truth — the onboarding's "what's new" slides and the
// always-accessible help library both read from this catalog.
//
// Add a new feature row here and it shows up in both surfaces. The
// IconData picker is the same lucide-ish material set the rest of the
// app uses; localisation is a future pass — strings are English-only
// for now (matches the rest of the home screen).

import 'package:flutter/material.dart';

@immutable
class HelpItem {
  const HelpItem({
    required this.title,
    required this.summary,
    required this.steps,
    this.icon = Icons.help_outline,
    this.remoteHint,
    this.touchHint,
    this.tvOnly = false,
  });

  final String title;
  final String summary;
  final List<String> steps;
  final IconData icon;

  /// TV remote button(s) that trigger this feature, if any.
  /// Rendered as a "On your remote:" pill in the help card.
  final String? remoteHint;

  /// Touch / keyboard equivalent, surfaced as a "On phone / tablet:" pill.
  final String? touchHint;

  /// When true, only show this item on TV (LEANBACK launcher).
  /// Phone users don't have a Bravia remote — surfacing TV-only
  /// shortcuts to them clutters the help screen.
  final bool tvOnly;
}

@immutable
class HelpSection {
  const HelpSection({
    required this.title,
    required this.items,
    this.icon = Icons.bookmark_border,
  });
  final String title;
  final IconData icon;
  final List<HelpItem> items;
}

/// Master help content. The screen renders these sections in order; the
/// onboarding screen picks the FIRST item from each section as a 5-slide
/// teaser so users see one card per major feature area.
const helpSections = <HelpSection>[
  HelpSection(
    title: 'Reading',
    icon: Icons.menu_book_outlined,
    items: [
      HelpItem(
        title: 'Open a PDF in book mode',
        summary: 'Two-page spread + page-flip animation for long-form reading.',
        icon: Icons.menu_book_outlined,
        steps: [
          'Open the Library from the AppBar (book icon).',
          'Tap a PDF — it opens in the BookViewer.',
          'Pinch / scroll / arrow-keys to zoom; tap the F key (or Yellow remote button) to enter fullscreen.',
          'Resume picks up where you left off — last page is auto-saved.',
        ],
        remoteHint: 'Yellow button — toggle fullscreen',
        touchHint:  'F key — toggle fullscreen',
      ),
      HelpItem(
        title: 'Jump to a page',
        summary: 'Type any digit anywhere in the BookViewer to bring up the jump dialog.',
        icon: Icons.numbers,
        steps: [
          'Inside any book, press any number key (0–9).',
          'The jump-to-page dialog opens, pre-filled with the digit you pressed.',
          'Type the rest, press Enter.',
        ],
        remoteHint: 'Numeric remote keys (0–9)',
        touchHint:  'Any digit on keyboard',
      ),
      HelpItem(
        title: 'Read aloud (TTS)',
        summary: 'System-installed TTS or Piper / Kokoro / eSpeak via Pro\'s AI backend.',
        icon: Icons.volume_up,
        steps: [
          'In the BookViewer top bar, tap the speaker icon.',
          'A karaoke strip highlights the word being spoken.',
          'Press Pause / Play on your remote to toggle, or tap the icon again.',
          'Settings → Read aloud lets you switch engines, voices, and language.',
        ],
        remoteHint: 'Play / Pause — toggle; Stop / Mute — stop',
        touchHint:  'Speaker icon in BookViewer top bar',
      ),
    ],
  ),
  HelpSection(
    title: 'Sticky Notes',
    icon: Icons.sticky_note_2_outlined,
    items: [
      HelpItem(
        title: 'Capture a sticky note',
        summary: 'Text, voice, image, or handwriting — all four kinds in one tap.',
        icon: Icons.sticky_note_2_outlined,
        steps: [
          'Tap the Sticky Notes icon in the home AppBar (yellow square).',
          'Tap "Capture" — a sheet with four buttons opens.',
          'Pick Text / Voice / Image / Sketch. Each opens a capture screen tuned for that kind.',
          'Save returns you to the grid. Notes captured while inside a book auto-pin to that book + page.',
        ],
        remoteHint: 'Green button — capture from inside any book',
        touchHint:  'Sticky Notes icon (yellow square) in AppBar',
      ),
      HelpItem(
        title: 'Find a note from a specific book',
        summary: 'Notes auto-tag the book + page where they were captured.',
        icon: Icons.search,
        steps: [
          'Open Sticky Notes from the AppBar.',
          'Use the search box (top) to filter by title or body.',
          'Use the kind chips (Text / Voice / Image / Sketch) to narrow further.',
          'Each card shows "Book · p.N" so you can jump back to the source.',
        ],
        touchHint:  'Search box + filter chips at top of Notes screen',
      ),
      HelpItem(
        title: 'Pin / archive a note',
        summary: 'Pinned notes float to the top; archived go to Trash for 30 days.',
        icon: Icons.push_pin_outlined,
        steps: [
          'Long-press any note card.',
          'A sheet lets you Pin, Move to Trash, Restore, or Delete forever.',
          'The trash icon top-right of the Notes screen toggles Trash view.',
        ],
      ),
    ],
  ),
  HelpSection(
    title: 'TV Remote',
    icon: Icons.tv_outlined,
    items: [
      HelpItem(
        title: 'Page turns without leaving fullscreen',
        summary: 'Channel Up/Down or Page Up/Down — the reading sequence stays uninterrupted.',
        icon: Icons.swap_horiz,
        tvOnly: true,
        steps: [
          'In any book, press F (or the Yellow remote button) to enter fullscreen.',
          'Channel Up = previous page. Channel Down = next page.',
          'Some remotes deliver these as PageUp/PageDown — both work.',
          'Fast Forward = +10 pages, Rewind = −10 pages.',
        ],
        remoteHint: 'Channel ▲▼ — page; FF/Rewind — ±10 pages',
      ),
      HelpItem(
        title: 'Zoom + scroll on the page',
        summary: 'D-pad to the zoom cluster (bottom-right) or use Volume keys.',
        icon: Icons.zoom_in,
        tvOnly: true,
        steps: [
          'Floating cluster bottom-right has +, -, and 1:1 reset.',
          'D-pad navigates onto them — each shows a cyan focus ring.',
          'Press OK to activate. The current zoom % is displayed in the middle.',
          'Once zoomed (>100%), Volume Up/Down scrolls vertically within the page.',
        ],
        remoteHint: 'D-pad + OK on the zoom cluster · Volume ▲▼ — scroll',
      ),
      HelpItem(
        title: 'Quick-action buttons',
        summary: 'The four coloured buttons on Bravia / Fire TV are mapped to common actions.',
        icon: Icons.palette_outlined,
        tvOnly: true,
        steps: [
          'Red = toggle bookmark on this page.',
          'Green = capture a sticky note (with location ref to this book/page).',
          'Yellow = toggle fullscreen.',
          'Blue = toggle Read Aloud (TTS).',
          'F1–F4 mirror the colours on emulators / PC remote apps.',
        ],
        remoteHint: 'Red / Green / Yellow / Blue',
      ),
      HelpItem(
        title: 'Voice command via the mic key',
        summary: 'Long-press the remote mic — Pro now appears in the assistant\'s app picker.',
        icon: Icons.mic_none,
        tvOnly: true,
        steps: [
          'Press the mic key on your Bravia / Fire TV remote.',
          'Speak the command: "open scanner", "go to library", "page 42", etc.',
          'The first time, Android may ask which app to route to — pick Interact Pro and tick "always".',
          'On the home screen, the in-app mic icon (next to Account) does the same thing without leaving the app.',
        ],
        remoteHint: 'Mic key on remote, OR mic icon in home AppBar',
      ),
    ],
  ),
  HelpSection(
    title: 'AI & Tools',
    icon: Icons.auto_awesome,
    items: [
      HelpItem(
        title: 'OCR a scanned PDF',
        summary: 'Pro\'s Surya OCR backend turns image-only PDFs into searchable text.',
        icon: Icons.text_snippet_outlined,
        steps: [
          'Open Settings → Batch OCR (or use the overflow ⋮ menu in the home AppBar).',
          'Pick the PDF, tap Start. Progress bar shows per-page status.',
          'When done, the text layer is searchable and the TTS engine can read it.',
        ],
      ),
      HelpItem(
        title: 'Identify an image',
        summary: 'Snap or upload — get a description, OCR-extracted text, and tags.',
        icon: Icons.image_search,
        steps: [
          'AppBar ⋮ → Identify image.',
          'Snap with the camera OR pick from the gallery.',
          'The result screen shows the AI\'s description + extracted text + matched tags.',
        ],
      ),
      HelpItem(
        title: 'AR measure / handwriting',
        summary: 'Bundled tools for field notes and quick sketches.',
        icon: Icons.straighten_outlined,
        steps: [
          'AppBar ⋮ → AR measure (camera-based) or Write by hand (canvas).',
          'For longer handwriting, AppBar ⋮ → Transcribe handwriting runs Surya OCR over the canvas.',
        ],
      ),
    ],
  ),
  HelpSection(
    title: 'Account & Sync',
    icon: Icons.cloud_outlined,
    items: [
      HelpItem(
        title: 'Sign in / Trial',
        summary: '7-day trial without an account; Pro unlocks via OTP login.',
        icon: Icons.account_circle_outlined,
        steps: [
          'Tap the Account icon in the home AppBar.',
          'Phone or email → receive OTP → enter → done.',
          'The Account screen also shows trial status + reading-time stats.',
        ],
      ),
      HelpItem(
        title: 'Sync PDFs across devices',
        summary: 'VPS storage keeps your library + bookmarks in sync.',
        icon: Icons.sync,
        steps: [
          'Settings → Sync → toggle "Auto-sync on save" on.',
          'PDFs you annotate are uploaded automatically.',
          'On a new device after sign-in, the library pulls everything from the VPS.',
        ],
      ),
    ],
  ),
];
