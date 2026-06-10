
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../../core/layout/responsive.dart';
import '../../../ocr/data/advanced_ocr_service.dart';
import '../../../tts/data/tts_service.dart';
import '../../../tts/presentation/widgets/karaoke_strip.dart';
import '../../../annotations/presentation/annotation_edit_controller.dart';
import '../../../annotations/presentation/widgets/annotation_tool_palette.dart';
import '../../data/bookmark_store.dart';
import '../../data/flip_sound_controller.dart';
import '../widgets/page_flip.dart';
// Sticky notes — exposes currentNoteLocationProvider so any note
// captured while a book is open auto-pins to (documentId, pageIndex).
// We resolve the documentId from widget.pdfPath via the PDF repo +
// reset the provider on dispose so notes captured later (e.g. from the
// home screen) don't inherit this book's location.
import '../../../sticky_notes/data/sticky_note_repository.dart';
import '../../../sticky_notes/presentation/screens/note_capture_sheet.dart';
import '../../../../core/storage/app_database.dart' show appDatabaseProvider;

/// Page-flip "book mode" viewer. Distinct from the regular viewer (which
/// supports annotations, signing, search) — this one is read-only and
/// animation-rich. Use case: long-form reading.
///
/// We render each page on demand via `pdfx` and cache the bytes in a map
/// keyed by page index. Dropped from cache on screen pop. The flip widget
/// asks for [pageCount] pages and `builder(index)` to materialise each.
class BookViewerScreen extends ConsumerStatefulWidget {
  const BookViewerScreen({required this.pdfPath, super.key});
  final String pdfPath;

  @override
  ConsumerState<BookViewerScreen> createState() => _BookViewerScreenState();
}

class _BookViewerScreenState extends ConsumerState<BookViewerScreen> {
  pdfx.PdfDocument? _doc;
  int _pageCount = 0;
  bool _ready = false;
  String? _error;
  final Map<int, Uint8List> _pageCache = {};
  final Set<int> _inFlight = {};
  final GlobalKey<PageFlipState> _flipKey = GlobalKey<PageFlipState>();

  /// Mirror of the flip widget's currentPage so the spread view + bottom
  /// bar can rebuild when the page changes without us trying to use the
  /// PageFlipState as a Listenable (it isn't).
  int _currentPage = 0;

  /// PdfDocuments.id (UUID) for the file open in this viewer. Resolved
  /// from widget.pdfPath inside _open(); nullable because resolution is
  /// async and the user can pop the screen before we finish.
  String? _documentId;

  /// Programmatic zoom level (1.0 .. 5.0). Driven by the TV-remote-
  /// accessible +/-/reset cluster in the bottom-right corner so D-pad
  /// users can zoom without a touch screen. Resets to 1.0 on page change
  /// so the new page starts in fit-to-screen view.
  double _zoomScale = 1.0;
  static const double _zoomStep   = 0.25;
  static const double _zoomMin    = 1.0;
  static const double _zoomMax    = 5.0;

  void _zoomIn()    => setState(() => _zoomScale = (_zoomScale + _zoomStep).clamp(_zoomMin, _zoomMax));
  void _zoomOut()   => setState(() {
        _zoomScale = (_zoomScale - _zoomStep).clamp(_zoomMin, _zoomMax);
        if (_zoomScale == 1.0) { _panX = 0; _panY = 0; }  // pan irrelevant at fit
      });
  void _zoomReset() => setState(() { _zoomScale = 1.0; _panX = 0; _panY = 0; });

  /// Pan offset within the current page, in logical pixels. Driven by
  /// the TV remote's Volume Up / Down (vertical scroll) and Channel
  /// Up / Down on TVs without channel keys. Only meaningful when zoomed
  /// (scale > 1.0) — at 1:1 the page fits the viewport, so panning is
  /// a no-op. Resets on page change + zoom reset.
  double _panX = 0.0;
  double _panY = 0.0;
  static const double _panStep = 120.0;
  static const double _panMax  = 2000.0; // soft cap; InteractiveViewer clamps the rest visually

  /// Scroll up within the current page. No-op when fit-to-screen.
  void _scrollUp() {
    if (_zoomScale <= 1.0) return;
    setState(() => _panY = (_panY - _panStep).clamp(-_panMax, _panMax));
  }

  /// Scroll down within the current page.
  void _scrollDown() {
    if (_zoomScale <= 1.0) return;
    setState(() => _panY = (_panY + _panStep).clamp(-_panMax, _panMax));
  }

  /// Page turn — previous. Wraps the PageFlip jumpTo() + currentPage
  /// sync + render-ahead in one helper so TV remote handlers stay tiny.
  void _pageBack() {
    if (_currentPage <= 0) return;
    final target = _currentPage - 1;
    _flipKey.currentState?.jumpTo(target);
    _onPageChanged(target);
    _renderPage(target);
  }

  /// Page turn — next.
  void _pageForward() {
    if (_currentPage + 1 >= _pageCount) return;
    final target = _currentPage + 1;
    _flipKey.currentState?.jumpTo(target);
    _onPageChanged(target);
    _renderPage(target);
  }

  /// User override for single vs spread layout. null = "auto" (default —
  /// uses screen-size + orientation heuristic). true = force two-page
  /// spread. false = force single-page. Top-bar toggle button cycles
  /// auto → single → spread → auto. Per-session only; not persisted —
  /// most users will be happy with auto for the duration of one read.
  bool? _spreadOverride;

  /// Mirror of the persisted bookmark set for the current PDF. Loaded
  /// once on open; updated synchronously in-memory whenever the user
  /// toggles a bookmark so the icon updates immediately, then written
  /// back to SharedPreferences in the background.
  Set<int> _bookmarks = const {};
  BookmarkStore? _store;

  /// Reading-time tracker — incremented every second the screen is
  /// foregrounded. Persisted alongside the bookmark set.
  Timer? _readingTicker;
  DateTime _sessionStart = DateTime.now();

  /// TTS — speak() is routed through the user's currently-selected
  /// engine (System / Piper / Kokoro / eSpeak) via
  /// `activeTtsServiceProvider`. We hold a reference to the LAST
  /// service used so stop() / dispose() can stop the same engine that
  /// was playing — earlier versions kept a dead local FlutterTts and
  /// called .stop() on it while speak() went through the provider,
  /// meaning Stop never actually stopped anything.
  TtsService? _activeTtsSvc;
  bool _ttsPlaying = false;

  /// Immersive / full-screen mode (#252 — 2026-05-20). When true, hides
  /// the top bar, bottom bar, and karaoke strip so only the page is
  /// visible. Toggled via remote 'F' key or the FullScreen icon in the
  /// top bar. State is per-session (not persisted) — users tend to flip
  /// in and out of full-screen often and a sticky preference is more
  /// annoying than helpful.
  bool _immersive = false;

  /// Audio player for the page-flip sound effect (#252). Lazy-init on
  /// first page change so we don't pay the engine cost on launch.
  /// Reused across flips — creating a fresh AudioPlayer per flip on
  /// Android leaks the underlying MediaPlayer instance until GC.
  AudioPlayer? _flipSfx;

  @override
  void initState() {
    super.initState();
    _open();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Sticky-notes wiring (task #260) — set the current location ref AFTER
    // first frame so the provider is ready before any FAB capture inside
    // this screen. _open() will refine it with the real documentId +
    // pageIndex once the PDF resolves. contextRoute='book-viewer' is the
    // fallback label the Notes screen renders when documentId is missing
    // (e.g. PDF not yet in the library DB).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(currentNoteLocationProvider.notifier).state = NoteLocationRef(
        documentId: _documentId,
        pageIndex: _currentPage,
        contextRoute: 'book-viewer',
      );
    });
    // 10-second tick — rebuilds so the reading-time chip ticks up live
    // AND flushes the accumulated session-elapsed to storage on every
    // tick. The earlier version only flushed on dispose, so a force-kill
    // or OOM crash lost the entire session. With per-tick autosave the
    // worst-case loss is the 10-second window between ticks.
    _sessionStart = DateTime.now();
    _readingTicker = Timer.periodic(
      const Duration(seconds: 10),
      (_) {
        if (!mounted) return;
        _flushReadingElapsed();
        setState(() {}); // redraw the chip
      },
    );
  }

  /// Accumulates the current session's elapsed seconds into the
  /// BookmarkStore and resets `_sessionStart` to "now". Called every
  /// 10s by the ticker and once more from dispose() for the final
  /// sub-10s tail.
  ///
  /// Caps each flush at 4 hours so a forgotten-open-overnight tab
  /// can't poison the total in a single write.
  void _flushReadingElapsed() {
    final store = _store;
    if (store == null) return;
    final now = DateTime.now();
    final elapsed = now.difference(_sessionStart).inSeconds;
    if (elapsed <= 0) return;
    final capped = elapsed.clamp(0, 4 * 60 * 60);
    // ignore: discarded_futures
    store.addReadingSeconds(widget.pdfPath, capped);
    _sessionStart = now;
  }

  /// Cumulative reading time for THIS PDF including the current session.
  /// Drives the top-bar chip. Returns "Just started" for the first
  /// minute, then "12 min", "1 h", "1 h 23 min", etc.
  ///
  /// Note: `_flushReadingElapsed` now writes session deltas back to
  /// the store every 10s and resets `_sessionStart`, so the unflushed
  /// session tail is always ≤ 10s. The `accumulated + session` math
  /// below remains correct in either world.
  String _formattedReadingTime() {
    final store = _store;
    final accumulated = store?.totalReadingSeconds(widget.pdfPath) ?? 0;
    final session = DateTime.now().difference(_sessionStart).inSeconds;
    final total = accumulated + session.clamp(0, 4 * 60 * 60);
    if (total < 60) return 'Just started';
    final mins = total ~/ 60;
    if (mins < 60) return '$mins min';
    final hours = mins ~/ 60;
    final rem = mins % 60;
    return rem == 0 ? '${hours}h' : '${hours}h ${rem}m';
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _readingTicker?.cancel();
    // ignore: discarded_futures
    _activeTtsSvc?.stop();
    final store = _store;
    if (store != null) {
      // Persist last viewed page so the next open resumes here.
      // ignore: discarded_futures
      store.setLastPage(widget.pdfPath, _currentPage + 1);
      // Flush the final sub-10s session tail. Per-tick autosave above
      // has already captured the rest, so this is the last few seconds
      // since the previous tick.
      _flushReadingElapsed();
    }
    _doc?.close();
    // Release the audio player so the underlying Android MediaPlayer
    // doesn't leak until GC. unawaited because dispose() can't be async.
    unawaited(_flipSfx?.dispose());
    // Clear the sticky-notes location ref so notes captured AFTER the
    // user pops the viewer don't inherit this book's documentId.
    // ConsumerState.dispose() runs synchronously, so we read() (not watch).
    try {
      ref.read(currentNoteLocationProvider.notifier).state =
          NoteLocationRef.empty;
    } catch (_) {
      // ProviderScope may already be torn down on app exit — swallow.
    }
    super.dispose();
  }

  Future<void> _open() async {
    try {
      // Bookmarks + last-page load in parallel with PDF open — both
      // hit SharedPreferences and are fast, but parallelising shaves
      // ~10ms off cold-start.
      final storeFut = ref.read(bookmarkStoreProvider.future);
      final doc = await pdfx.PdfDocument.openFile(widget.pdfPath);
      final store = await storeFut;
      // Resolve the PdfDocuments.id (UUID) for the open file so sticky
      // notes captured here can FK-link to the document. Best-effort —
      // if the file isn't yet in the library DB (e.g. opened directly
      // from a share-sheet), documentId stays null and the note still
      // saves with contextRoute='book-viewer'.
      final db = ref.read(appDatabaseProvider);
      final docRow = await db.documentByPath(widget.pdfPath);
      _documentId = docRow?.id;
      if (mounted) {
        ref.read(currentNoteLocationProvider.notifier).state = NoteLocationRef(
          documentId: _documentId,
          pageIndex: _currentPage,
          contextRoute: 'book-viewer',
        );
      }
      if (!mounted) return;
      final resume = store.lastPage(widget.pdfPath);
      setState(() {
        _doc = doc;
        _pageCount = doc.pagesCount;
        _ready = true;
        _store = store;
        _bookmarks = store.bookmarks(widget.pdfPath);
        // Resume from last page if present and valid; otherwise start
        // at page 0. 1-based on disk; 0-based internally.
        if (resume != null && resume >= 1 && resume <= doc.pagesCount) {
          _currentPage = resume - 1;
        }
      });
      // Pre-render the current page + neighbours.
      _renderPage(_currentPage);
      if (_currentPage + 1 < _pageCount) _renderPage(_currentPage + 1);
      if (_currentPage - 1 >= 0) _renderPage(_currentPage - 1);
      // If we resumed past page 0, jump the flip widget once it mounts.
      if (_currentPage != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _flipKey.currentState?.jumpTo(_currentPage);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _ready = true;
      });
    }
  }

  Future<void> _toggleBookmark() async {
    final store = _store;
    if (store == null) return;
    final oneBased = _currentPage + 1;
    await store.toggle(widget.pdfPath, oneBased);
    if (!mounted) return;
    setState(() => _bookmarks = store.bookmarks(widget.pdfPath));
    final msg = _bookmarks.contains(oneBased)
        ? 'Bookmarked page $oneBased'
        : 'Removed bookmark on page $oneBased';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// Extract text from the current page and start TTS. Best-effort —
  /// for image-only PDFs there's nothing to extract and the snackbar
  /// surfaces that gracefully. Phase 2 will route those through
  /// `advancedOcrServiceProvider` (Surya backend).
  Future<void> _toggleTts() async {
    if (_ttsPlaying) {
      // Stop the SAME engine that's playing — not a dead local
      // FlutterTts. Without this, tapping the speaker icon during
      // playback used to look like a no-op.
      await _activeTtsSvc?.stop();
      if (mounted) setState(() => _ttsPlaying = false);
      return;
    }
    final doc = _doc;
    if (doc == null) return;

    // Pipeline:
    //   1. Extract text from current page — Surya backend (always
    //      required; PDFs are images on this code path).
    //   2. Read text aloud via the user's chosen TTS engine — System
    //      (flutter_tts) or Piper (backend). Settings → Read aloud.
    final ocr = ref.read(advancedOcrServiceProvider);
    if (!ocr.isAvailable) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Read-aloud needs the Advanced OCR backend. This build '
            'doesn\'t have the AI secret baked in.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    // Get the rendered bytes for the current page from the render cache.
    Uint8List? bytes = _pageCache[_currentPage];
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Preparing page for read-aloud…'),
          duration: Duration(seconds: 2),
        ),
      );
      await _renderPage(_currentPage);
      bytes = _pageCache[_currentPage];
      if (bytes == null) return;
    }

    if (!mounted) return;
    setState(() => _ttsPlaying = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Extracting text via Surya (a few seconds)…'),
        duration: Duration(seconds: 3),
      ),
    );

    try {
      final result = await ocr.analyze(
        imageBytes: bytes,
        pageHint: _currentPage + 1,
      );
      final text = result.flatText.trim();
      if (text.isEmpty) {
        if (mounted) {
          setState(() => _ttsPlaying = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(
              'No text found on this page (engine: ${result.engine}).',
            ),),
          );
        }
        return;
      }
      // Hand off to the user's chosen TTS engine. SystemTts uses the
      // device's installed engine (zero config, works offline). Piper
      // hits /api/tts/speak with the user's picked voice.
      final ttsSvc = await ref.read(activeTtsServiceProvider.future);
      _activeTtsSvc = ttsSvc; // so Stop/dispose can hit the right engine
      // Best-effort language hint — Surya may return it; otherwise null
      // (engines fall back to system default).
      await ttsSvc.speak(text, langHint: result.languageDetected);
      // Mirror engine's playing state into local _ttsPlaying so the
      // icon flips back when it completes.
      void onChange() {
        if (!mounted) return;
        setState(() => _ttsPlaying = ttsSvc.isPlaying);
        if (!ttsSvc.isPlaying) {
          ttsSvc.playingListenable.removeListener(onChange);
        }
      }
      ttsSvc.playingListenable.addListener(onChange);
    } catch (e) {
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Read-aloud failed: $e')),
      );
    }
  }

  Future<void> _renderPage(int index) async {
    if (_pageCache.containsKey(index) || _inFlight.contains(index)) return;
    final doc = _doc;
    if (doc == null) return;
    _inFlight.add(index);
    try {
      final page = await doc.getPage(index + 1);
      // Render at ~2× device scale for crisp text on retina screens
      // without exploding memory for long PDFs.
      final mq = MediaQuery.of(context);
      final targetWidth = mq.size.width * mq.devicePixelRatio;
      final scale = targetWidth / page.width;
      final img = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: pdfx.PdfPageImageFormat.jpeg,
        quality: 88,
        backgroundColor: '#FFFFFF',
      );
      await page.close();
      if (!mounted || img == null) {
        _inFlight.remove(index);
        return;
      }
      setState(() {
        _pageCache[index] = img.bytes;
      });
    } finally {
      _inFlight.remove(index);
    }
  }

  /// Trim the cache so we don't grow without bound on long PDFs. Keeps
  /// the current page +/- 2 in memory.
  void _trimCache(int currentIndex) {
    final keep = <int>{
      for (var i = currentIndex - 2; i <= currentIndex + 2; i++)
        if (i >= 0 && i < _pageCount) i,
    };
    _pageCache.removeWhere((k, _) => !keep.contains(k));
  }

  void _onPageChanged(int index) {
    if (mounted) {
      setState(() {
        _currentPage = index;
        _zoomScale   = 1.0; // reset zoom — new page starts fit-to-screen
        _panX = 0.0; _panY = 0.0;
      });
    }
    // Keep the sticky-notes location provider in sync — any note
    // captured at this moment auto-pins to the page just turned to.
    if (mounted) {
      ref.read(currentNoteLocationProvider.notifier).state = NoteLocationRef(
        documentId: _documentId,
        pageIndex: index,
        contextRoute: 'book-viewer',
      );
    }
    // Page-flip SFX (#252). assets/sfx/page_flip.wav ships in the
    // pubspec assets list — generated 2026-05-20 via the scipy
    // noise+decaying-tone recipe (see assets/sfx/README.md). If the
    // asset is missing for any reason (e.g. build step skipped it)
    // the catch swallows silently so page navigation never breaks
    // because of audio.
    _playFlipSfx();
    // Pre-fetch the next page so the next flip is cache-warm.
    if (index + 1 < _pageCount) _renderPage(index + 1);
    if (index - 1 >= 0) _renderPage(index - 1);
    _trimCache(index);
  }

  Future<void> _playFlipSfx() async {
    try {
      // #273 — read user's flip-sound preference. `none` short-circuits.
      // Default for new installs is `soft` (brushed-noise envelope —
      // closest to real paper). The original synthesised tone is
      // available as `echo (legacy)` for users who preferred it.
      final state = ref.read(flipSoundControllerProvider);
      if (!state.sound.isEnabled) return;

      _flipSfx ??= AudioPlayer()
        ..setReleaseMode(ReleaseMode.stop)
        ..setPlayerMode(PlayerMode.lowLatency);
      // stop() before play() so rapid flips don't queue up overlapping
      // playback (which on Android sounds like a thumb-drumroll).
      await _flipSfx!.stop();
      await _flipSfx!.play(
        AssetSource(state.sound.asset),
        volume: state.volume,
      );
    } catch (_) {
      // Audio is non-essential to navigation.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFFF7EFDC),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Could not open: $_error')),
      );
    }
    // Two-page spread when both: tablet-or-wider AND landscape. A tablet
    // in portrait is wide enough for one big page; landscape is where a
    // proper book spread looks right. User can override via the top-bar
    // toggle (auto → single → spread → auto), which sets _spreadOverride.
    final mq = MediaQuery.of(context);
    final isWide = WindowSize.of(context).isTabletOrWider;
    final isLandscape = mq.size.width > mq.size.height;
    final autoSpread = isWide && isLandscape;
    final spreadMode = _spreadOverride ?? autoSpread;

    return Scaffold(
      backgroundColor: const Color(0xFFE8DABA),
      // Top-level Focus observer — digit press anywhere on the
      // BookViewer opens the jump-to-page dialog. `canRequestFocus:
      // false` is the critical bit: this widget OBSERVES key events
      // as they bubble up from the focused chevron/page-button, but
      // never CLAIMS focus itself. The previous version used
      // KeyboardListener with `..requestFocus()` which stole focus
      // from the chevrons and made D-pad navigation impossible.
      body: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          // #268 TV-fullscreen escape — Bravia / Fire TV remotes don't
          // have an F key, so the only way out of immersive mode was
          // unreachable on the remote. Map BACK / ESCAPE / goBack to
          // "exit immersive" when immersive is on; otherwise let the
          // key fall through to default Navigator pop behaviour.
          final k = event.logicalKey;
          if (_immersive &&
              (k == LogicalKeyboardKey.escape ||
                  k == LogicalKeyboardKey.goBack ||
                  k == LogicalKeyboardKey.browserBack)) {
            setState(() => _immersive = false);
            return KeyEventResult.handled;
          }
          // ── #261 TV-remote reading-flow shortcuts ──────────────────
          // Volume Up/Down: scroll within the current page (only when
          // zoomed). Channel Up/Down: previous / next page. Both work
          // in fullscreen WITHOUT exiting immersive mode so the reading
          // sequence stays uninterrupted on Sony Bravia + Fire TV.
          //
          // Note: on many Android TVs the system intercepts volume keys
          // for media-session volume control. When that happens the key
          // event never reaches us — there's no Dart-side workaround.
          // The fallback for those devices is the D-pad-focusable
          // _ZoomCluster + the prev/next page tap zones at the screen
          // edges (already shipped). Channel keys are less commonly
          // intercepted; they work on Bravia + most Fire TVs.
          if (k == LogicalKeyboardKey.audioVolumeUp) {
            _scrollUp();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.audioVolumeDown) {
            _scrollDown();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.channelUp) {
            _pageBack();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.channelDown) {
            _pageForward();
            return KeyEventResult.handled;
          }
          // Arrow keys as a TV-remote-friendly fallback for page nav
          // (some remotes deliver left/right D-pad as arrow keys when
          // there's no focused widget; the _ZoomCluster handles arrows
          // when itself focused, but at rest these are free for paging).
          if (k == LogicalKeyboardKey.pageUp) {
            _pageBack();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.pageDown) {
            _pageForward();
            return KeyEventResult.handled;
          }
          // ── #262 TV-remote feature shortcuts ──────────────────────
          // Media keys + the four Bravia/Fire-TV color buttons map to
          // common actions so the reader is fully usable from the
          // couch without a keyboard. Bindings:
          //
          //   Play / Pause / MediaPlayPause   → toggle TTS read-aloud
          //   MediaStop                       → stop TTS
          //   MediaFastForward                → jump +10 pages
          //   MediaRewind                     → jump −10 pages
          //   ColorRed     (F1 fallback)      → toggle bookmark on this page
          //   ColorGreen   (F2 fallback)      → capture a sticky note
          //                                     (text/voice/image/sketch)
          //   ColorYellow  (F3 fallback)      → toggle immersive (fullscreen)
          //   ColorBlue    (F4 fallback)      → toggle TTS (alternate to media keys)
          //
          // F1-F4 are included because the Android TV emulator + some
          // PC remote-control apps deliver the color buttons as F-keys
          // instead of the dedicated colorRed/Green/etc constants.
          if (k == LogicalKeyboardKey.mediaPlay ||
              k == LogicalKeyboardKey.mediaPause ||
              k == LogicalKeyboardKey.mediaPlayPause) {
            // ignore: discarded_futures
            _toggleTts();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.mediaStop) {
            if (_ttsPlaying) {
              // ignore: discarded_futures
              _toggleTts();
            }
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.mediaFastForward) {
            // Jump +10 pages, clamped. Useful for skimming.
            final target = (_currentPage + 10).clamp(0, _pageCount - 1);
            _flipKey.currentState?.jumpTo(target);
            _onPageChanged(target);
            _renderPage(target);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.mediaRewind ||
              k == LogicalKeyboardKey.mediaTrackPrevious) {
            final target = (_currentPage - 10).clamp(0, _pageCount - 1);
            _flipKey.currentState?.jumpTo(target);
            _onPageChanged(target);
            _renderPage(target);
            return KeyEventResult.handled;
          }
          // Flutter SDK names the four TV remote color buttons with the
          // F-key position embedded (colorF0Red, colorF1Green, etc.) per
          // the HID spec. F1-F4 fallbacks cover the Android TV emulator
          // and PC remote-control apps that deliver them as plain F-keys.
          if (k == LogicalKeyboardKey.colorF0Red    || k == LogicalKeyboardKey.f1) {
            // ignore: discarded_futures
            _toggleBookmark();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.colorF1Green  || k == LogicalKeyboardKey.f2) {
            // currentNoteLocationProvider is already kept in sync by the
            // BookViewer's lifecycle hooks (see initState / _open /
            // _onPageChanged / dispose), so the capture sheet auto-pins
            // the note to (documentId, pageIndex) without any extra args.
            showNoteCaptureSheet(context);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.colorF2Yellow || k == LogicalKeyboardKey.f3) {
            setState(() => _immersive = !_immersive);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.colorF3Blue   || k == LogicalKeyboardKey.f4) {
            // ignore: discarded_futures
            _toggleTts();
            return KeyEventResult.handled;
          }
          // AudioVolumeMute as an alias for "stop TTS" since the user is
          // typically reaching for it to silence the speaker, and the
          // TTS chip is what's making the noise.
          if (k == LogicalKeyboardKey.audioVolumeMute) {
            if (_ttsPlaying) {
              // ignore: discarded_futures
              _toggleTts();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          }
          final ch = event.character;
          // Full-screen toggle (#252) — 'F' or 'f' anywhere on the
          // BookViewer flips chrome visibility. Handles BEFORE the
          // digit-handler so 'F' on a numeric keypad with shift doesn't
          // get gobbled by the jump-to-page dialog.
          if (ch != null && (ch == 'f' || ch == 'F')) {
            setState(() => _immersive = !_immersive);
            return KeyEventResult.handled;
          }
          if (ch == null || ch.isEmpty) return KeyEventResult.ignored;
          if (!RegExp(r'^[0-9]$').hasMatch(ch)) return KeyEventResult.ignored;
          // Run async work outside the synchronous handler.
          () async {
            if (!mounted) return;
            final target = await showJumpToPageDialog(
              context,
              totalPages: _pageCount,
              currentPage: _currentPage,
              prefilled: ch,
            );
            if (target != null && mounted) {
              _flipKey.currentState?.jumpTo(target - 1);
              setState(() => _currentPage = target - 1);
              _renderPage(target - 1);
            }
          }();
          return KeyEventResult.handled;
        },
        child: SafeArea(
        child: Stack(
          children: [
        Column(
          children: [
            // Full-screen (#252): hide chrome entirely when immersive.
            // We use a conditional widget rather than Visibility because
            // the bottom bar's onPrev/onNext still need to fire from
            // remote D-pad / F-toggle, but in immersive mode the user
            // gets there via PageFlip's own swipe + the global key
            // listener — no chrome means no focus targets to compete
            // with the InteractiveViewer.
            if (!_immersive)
            Consumer(
              builder: (context, ref, _) {
                final editState = ref.watch(annotationEditControllerProvider);
                final editCtrl =
                    ref.read(annotationEditControllerProvider.notifier);
                return _TopBar(
              title: p.basenameWithoutExtension(widget.pdfPath),
              onBack: () => context.pop(),
              spreadMode: spreadMode,
              isOverridden: _spreadOverride != null,
              canAutoSpread: autoSpread,
              isBookmarked: _bookmarks.contains(_currentPage + 1),
              onToggleBookmark: _toggleBookmark,
              ttsPlaying: _ttsPlaying,
              onToggleTts: _toggleTts,
              readingTimeLabel: _formattedReadingTime(),
              isImmersive: _immersive,
              onToggleImmersive: () =>
                  setState(() => _immersive = !_immersive),
              isEditing: editState.isEditing,
              onToggleEdit: () =>
                  editCtrl.selectTool(
                    editState.isEditing
                        ? AnnotationTool.none
                        : AnnotationTool.highlighter,
                  ),
              // The capture sheet pulls book + page from
              // currentNoteLocationProvider (already kept in sync by
              // the BookViewer's _onPageChanged + initState side
              // effects), so the resulting StickyNote auto-references
              // this book and page without any plumbing here.
              onAddStickyNote: () => showNoteCaptureSheet(context),
              onToggleSpread: () {
                setState(() {
                  // Cycle: auto → opposite-of-auto → restore-to-auto.
                  // If we're in auto (override null), force the
                  // opposite of what auto picked, so the toggle has a
                  // visible effect even on small screens. Tapping
                  // again restores auto.
                  if (_spreadOverride == null) {
                    _spreadOverride = !autoSpread;
                  } else {
                    _spreadOverride = null;
                  }
                });
              },
            );
              },
            ),
            Expanded(
              child: spreadMode
                  ? _SpreadView(
                      pageCount: _pageCount,
                      pageBytes: _pageCache,
                      flipKey: _flipKey,
                      immersive: _immersive,
                      currentPage: _currentPage,
                      onPageChanged: _onPageChanged,
                      onRender: _renderPage,
                    )
                  : PageFlip(
                      key: _flipKey,
                      pageCount: _pageCount,
                      onPageChanged: _onPageChanged,
                      builder: (_, index) => _PageView(
                        bytes: _pageCache[index],
                        index: index,
                        onMissing: () => _renderPage(index),
                        zoomScale: index == _currentPage ? _zoomScale : 1.0,
                        panX:      index == _currentPage ? _panX      : 0.0,
                        panY:      index == _currentPage ? _panY      : 0.0,
                        immersive: _immersive,
                      ),
                    ),
            ),
            // Karaoke "now reading" strip — auto-hides when TTS isn't
            // playing. Sits ABOVE the bottom bar so the spoken words
            // are visible without obscuring the page itself. Hidden
            // entirely in immersive mode (#252) — chrome is chrome.
            if (!_immersive)
              // ignore: discarded_futures
              Consumer(
                builder: (context, ref, _) {
                  final asyncSvc = ref.watch(activeTtsServiceProvider);
                  return asyncSvc.maybeWhen(
                    data: (svc) =>
                        KaraokeStrip(progress: svc.progressNotifier),
                    orElse: () => const SizedBox.shrink(),
                  );
                },
              ),
            if (!_immersive)
            _BottomBar(
              currentPage: _currentPage,
              totalPages: _pageCount,
              onPrev: () => _flipKey.currentState?.previous(),
              onNext: () => _flipKey.currentState?.next(),
              onJumpToPage: () async {
                final target = await showJumpToPageDialog(
                  context,
                  totalPages: _pageCount,
                  currentPage: _currentPage,
                );
                if (target != null && mounted) {
                  _flipKey.currentState?.jumpTo(target - 1);
                  setState(() => _currentPage = target - 1);
                  _renderPage(target - 1);
                  // Pre-fetch neighbours for instant flip after jump.
                  if (target < _pageCount) _renderPage(target);
                  if (target - 2 >= 0) _renderPage(target - 2);
                }
              },
            ),
          ],
        ),
            // ── #268 TV-fullscreen escape pill ────────────────────
            // Always-visible exit affordance when immersive — sits in
            // the top-right corner with the same focusable pattern as
            // _TvNavTile so D-pad lands on it and OK key fires.
            if (_immersive)
              Positioned(
                top: 8,
                right: 8,
                child: _ExitImmersivePill(
                  onTap: () => setState(() => _immersive = false),
                ),
              ),
            // ── #261 TV-remote zoom cluster ───────────────────────
            // Floats bottom-right in BOTH windowed and immersive
            // modes so Sony Bravia D-pad users can zoom into a chart
            // / footnote without pinching. Each button is a
            // FocusableActionDetector with cyan focus halo + OK/Enter/
            // GameButtonA activators matching _ExitImmersivePill, so
            // the remote's directional pad lands on them naturally.
            Positioned(
              right: 12,
              bottom: 12,
              child: _ZoomCluster(
                scale: _zoomScale,
                minScale: _zoomMin,
                maxScale: _zoomMax,
                onZoomIn:    _zoomIn,
                onZoomOut:   _zoomOut,
                onZoomReset: _zoomReset,
              ),
            ),
            // ── #269 annotation tool palette ──────────────────────
            // Auto-hides when AnnotationEditState.tool == none. The
            // Edit button in _TopBar toggles it on. Stack-positioned
            // bottom-center so it floats above the page without
            // blocking the page-flip gesture areas at the edges.
            const AnnotationToolPalette(),
          ],
        ),
      ),
      ),
    );
  }
}

/// Small pill that sits in the top-right corner of the BookViewer
/// when immersive mode is on. Touch-tap exits; D-pad OK / Enter /
/// Select / GameButtonA / Space also fire onTap so TV remotes have
/// a reliable escape from fullscreen.
class _ExitImmersivePill extends StatefulWidget {
  const _ExitImmersivePill({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_ExitImmersivePill> createState() => _ExitImmersivePillState();
}

class _ExitImmersivePillState extends State<_ExitImmersivePill> {
  bool _focused = false;

  static const _activate = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final ring = _focused ? const Color(0xFF22D3EE) : Colors.transparent;
    return FocusableActionDetector(
      autofocus: true,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _activate,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      mouseCursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: ring, width: 2),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: ring.withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.fullscreen_exit, color: Colors.white, size: 18),
              SizedBox(width: 6),
              Text(
                'Exit fullscreen',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// TV-remote-friendly zoom cluster — three round buttons (+, -, 1:1).
/// Lives in the bottom-right corner of the BookViewer's Stack so it's
/// reachable in both windowed and immersive modes. Each button mirrors
/// the _ExitImmersivePill focus-halo pattern (cyan ring on focus + Enter/
/// Select/GameButtonA activators) so Sony Bravia D-pad lands on them
/// without extra config.
///
/// Why a fixed-position cluster instead of a floating action button:
///   - FAB is a single button; zoom needs 3.
///   - Page-flip swipe areas claim the bottom edges. Anchoring to the
///     bottom-right corner avoids overlap with the next-page flip zone
///     on the right edge.
class _ZoomCluster extends StatelessWidget {
  const _ZoomCluster({
    required this.scale,
    required this.minScale,
    required this.maxScale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onZoomReset,
  });

  final double scale;
  final double minScale;
  final double maxScale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomReset;

  @override
  Widget build(BuildContext context) {
    final canIn  = scale < maxScale - 0.001;
    final canOut = scale > minScale + 0.001;
    final canReset = scale != 1.0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomIconButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            enabled: canOut,
            onTap: onZoomOut,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${(scale * 100).round()}%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _ZoomIconButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            enabled: canIn,
            onTap: onZoomIn,
          ),
          const SizedBox(width: 4),
          _ZoomIconButton(
            icon: Icons.fit_screen,
            tooltip: 'Reset zoom (1:1)',
            enabled: canReset,
            onTap: onZoomReset,
          ),
        ],
      ),
    );
  }
}

class _ZoomIconButton extends StatefulWidget {
  const _ZoomIconButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_ZoomIconButton> createState() => _ZoomIconButtonState();
}

class _ZoomIconButtonState extends State<_ZoomIconButton> {
  bool _focused = false;

  static const _activate = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select):      ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter):       ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space):       ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final ring   = _focused && widget.enabled
        ? const Color(0xFF22D3EE)
        : Colors.transparent;
    final iconColor = widget.enabled ? Colors.white : Colors.white38;
    return FocusableActionDetector(
      enabled: widget.enabled,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _activate,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (widget.enabled) widget.onTap();
            return null;
          },
        ),
      },
      mouseCursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: ring, width: 2),
              boxShadow: _focused && widget.enabled
                  ? [
                      BoxShadow(
                        color: ring.withValues(alpha: 0.5),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
            child: Icon(widget.icon, color: iconColor, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Two-page spread for landscape tablets / iPad. The flip widget still
/// drives the LEFT page (which carries the rotateY transform) — the
/// RIGHT page is a static neighbour. Tapping the right edge advances by
/// two; tapping the left edge goes back by two. This matches the
/// reading metaphor: in a real book, both pages turn together.
class _SpreadView extends StatelessWidget {
  const _SpreadView({
    required this.pageCount,
    required this.pageBytes,
    required this.flipKey,
    required this.currentPage,
    required this.onPageChanged,
    required this.onRender,
    this.immersive = false,
  });

  final int pageCount;
  // Was `Map<int, dynamic>` — caused dynamic→Uint8List? assignability errors
  // at every .pageBytes[index] usage. Tighten to the actual type the cache holds.
  final Map<int, Uint8List> pageBytes;
  final GlobalKey<PageFlipState> flipKey;

  /// Current page (0-indexed) — passed in from the parent's `setState`
  /// so this widget rebuilds without us having to wire `flipKey` into
  /// an AnimatedBuilder (PageFlipState isn't a Listenable).
  final int currentPage;
  final ValueChanged<int> onPageChanged;
  final void Function(int) onRender;

  /// Forwarded to both child _PageView instances so paper margin +
  /// shadow drop out in full-screen TV mode (zoom-bug fix 2026-05-21).
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final right = currentPage + 1;
    if (right < pageCount && !pageBytes.containsKey(right)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onRender(right));
    }
    return Row(
      children: [
        // Left page = the flippable one.
        Expanded(
          child: PageFlip(
            key: flipKey,
            pageCount: pageCount,
            onPageChanged: onPageChanged,
            builder: (_, index) => _PageView(
              bytes: pageBytes[index],
              index: index,
              onMissing: () => onRender(index),
              immersive: immersive,
            ),
          ),
        ),
        // Right page (current + 1). Static neighbour — doesn't flip in
        // sync with the left page in this first cut, but visually reads
        // as a real two-page spread once the page settles.
        Expanded(
          child: right >= pageCount
              ? const SizedBox.shrink()
              : _PageView(
                  bytes: pageBytes[right],
                  index: right,
                  onMissing: () => onRender(right),
                  immersive: immersive,
                ),
        ),
      ],
    );
  }
}

class _PageView extends StatefulWidget {
  const _PageView({
    required this.bytes,
    required this.index,
    required this.onMissing,
    this.zoomScale = 1.0,
    this.panX = 0.0,
    this.panY = 0.0,
    this.immersive = false,
  });
  final Uint8List? bytes;
  final int index;
  final VoidCallback onMissing;

  /// Programmatic zoom level (1.0 .. 5.0). Driven by the BookViewer's
  /// zoom overlay so TV-remote D-pad users can zoom without pinching.
  final double zoomScale;

  /// Programmatic pan offset in logical pixels. Driven by the
  /// TV-remote Volume Up / Down (vertical) so users can scroll within
  /// a zoomed page without a touch screen.
  final double panX;
  final double panY;

  /// When the parent is in immersive (full-screen) mode — typically TV
  /// — we drop the page paper margin + drop-shadow so the page fills
  /// the entire display. Without this, `InteractiveViewer` scales the
  /// page contents *inside* a small white rectangle in the middle of
  /// a gray screen, which on TV looks broken at 200%+ zoom. Bug fix
  /// 2026-05-21 (Bravia screenshot from user).
  final bool immersive;

  @override
  State<_PageView> createState() => _PageViewState();
}

class _PageViewState extends State<_PageView> {
  final TransformationController _xform = TransformationController();

  @override
  void initState() {
    super.initState();
    _applyTransform();
  }

  @override
  void didUpdateWidget(covariant _PageView old) {
    super.didUpdateWidget(old);
    if (old.zoomScale != widget.zoomScale ||
        old.panX != widget.panX ||
        old.panY != widget.panY) {
      _applyTransform();
    }
  }

  void _applyTransform() {
    final clamped = widget.zoomScale.clamp(1.0, 5.0);
    // Order matters: scale FIRST then translate. The translate values are
    // in scaled-image space, so a panY of 120 moves the visible viewport
    // down by 120/scale physical pixels — which feels right because the
    // user's mental model is "scroll the page", not "move the camera".
    _xform.value = Matrix4.identity()
      ..scale(clamped, clamped)
      ..translate(widget.panX, widget.panY);
  }

  @override
  void dispose() {
    _xform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bytes == null) {
      // Trigger a render lazily on first frame for off-screen pages
      // that the prefetcher hasn't reached yet.
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onMissing());
      return Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }
    // When immersive (TV full-screen) or actively zoomed > 1.0, the
    // page must occupy the entire available area so InteractiveViewer's
    // scaled child can paint across the whole screen. Otherwise the
    // 8/12-px margin + drop-shadow box clips the zoomed image to a
    // small rectangle in the middle of a gray void. See bug fix
    // 2026-05-21 (Bravia screenshot — user reported zoom not covering
    // the TV).
    final bool edgeToEdge = widget.immersive || widget.zoomScale > 1.0;
    final EdgeInsets margin = edgeToEdge
        ? EdgeInsets.zero
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 12);
    final BoxDecoration decoration = edgeToEdge
        ? const BoxDecoration(color: Colors.white)
        : BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          );
    return Container(
      decoration: decoration,
      margin: margin,
      child: ClipRect(
        // InteractiveViewer enables pinch-to-zoom on touch + scroll-to-
        // zoom on trackpad/mouse + arrow-key panning on keyboards.
        // Critical for dense PDFs where the user needs to zoom in on a
        // chart, footnote, or table cell. minScale 1 = "no zoom-out
        // below fit". maxScale 5 = 5× — beyond that the rasterized
        // image goes pixelly. The BookViewer's top-level KeyboardListener
        // additionally responds to '+' / '-' / '0' for keyboard zoom.
        //
        // TV-remote zoom (task #261): TransformationController lets the
        // BookViewer's focusable +/-/reset overlay drive zoom without a
        // touchscreen — Sony Bravia D-pad users couldn't pinch.
        //
        // In edge-to-edge mode (immersive or zoomed) we switch the
        // image fit from `contain` to `cover` so the page paints across
        // the full screen instead of letterboxing into the container
        // mid-air. `cover` clips the long edge — acceptable for a
        // zoomed page because the user is panning via Volume Up/Down
        // anyway. At zoom = 1 in immersive we still want `contain` so
        // the unzoomed page reads as one piece of paper.
        child: InteractiveViewer(
          transformationController: _xform,
          minScale: 1.0,
          maxScale: 5.0,
          panEnabled: true,
          scaleEnabled: true,
          child: SizedBox.expand(
            // SizedBox.expand forces the Image to fill the entire
            // InteractiveViewer viewport regardless of the page's
            // intrinsic aspect ratio. Combined with the BoxFit choice
            // below this is what makes the page actually cover the TV
            // when zoomed instead of sitting as a small island.
            child: Image.memory(
              widget.bytes!,
              fit: (edgeToEdge && widget.zoomScale > 1.0)
                  ? BoxFit.cover
                  : BoxFit.contain,
              gaplessPlayback: true,
              alignment: Alignment.center,
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.spreadMode,
    required this.isOverridden,
    required this.canAutoSpread,
    required this.onToggleSpread,
    required this.isBookmarked,
    required this.onToggleBookmark,
    required this.ttsPlaying,
    required this.onToggleTts,
    required this.readingTimeLabel,
    required this.isImmersive,
    required this.onToggleImmersive,
    required this.isEditing,
    required this.onToggleEdit,
    required this.onAddStickyNote,
  });

  /// Open the multi-modality NoteCaptureSheet (text / voice / image /
  /// handwriting) with currentNoteLocationProvider already pointed at
  /// this book + page — so the resulting StickyNote auto-pins to the
  /// page the user is reading. Added 2026-05-21 (user asked why notes
  /// weren't reachable while reading; entry only existed on the home
  /// AppBar).
  final VoidCallback onAddStickyNote;

  /// Pre-formatted "Read 12m" / "Read 1h 23m" / "Just started" string —
  /// the parent computes this from `BookmarkStore.formatReadingTime()`
  /// plus the current session's elapsed seconds, refreshing every ~30s
  /// via a Timer so the chip ticks up live.
  final String readingTimeLabel;
  final String title;
  final VoidCallback onBack;

  /// Final resolved mode (after override). True = two-page spread,
  /// false = single page.
  final bool spreadMode;

  /// True when the user has explicitly overridden auto-detection.
  /// Tapping the toggle then will REVERT to auto rather than flip
  /// to the opposite forced state. Drives the badge styling.
  final bool isOverridden;

  /// What auto would pick on the current screen. When false (small
  /// screen or portrait), the auto value is "single"; the toggle
  /// becomes a one-time "force spread anyway" affordance.
  final bool canAutoSpread;

  final VoidCallback onToggleSpread;

  final bool isBookmarked;
  final VoidCallback onToggleBookmark;
  final bool ttsPlaying;
  final VoidCallback onToggleTts;

  /// Full-screen state (#252). When true the parent hides this bar
  /// entirely — the icon shown here drives the entry into immersive
  /// mode; press 'F' anywhere on the BookViewer to toggle back out.
  final bool isImmersive;
  final VoidCallback onToggleImmersive;

  /// Annotation edit-mode state (#269). When true, the AnnotationTool
  /// Palette is visible at the bottom of the screen and gestures on
  /// the page produce strokes/shapes. Toggling off restores the
  /// reading experience.
  final bool isEditing;
  final VoidCallback onToggleEdit;

  @override
  Widget build(BuildContext context) {
    final brown = const Color(0xFF4F3017);
    // Layout strategy: back-arrow flush left, title-flexible (ellipsizes
    // when long, takes natural width when short), then a Spacer to push
    // the trailing affordance group to the right edge. Earlier version
    // used Expanded(Text(title)) which made the title eat all free
    // space — visually left-aligned title with every chip/icon flung
    // hard right ("footer shifted on left" report). Flexible + Spacer
    // keeps the bar balanced regardless of title length.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.brown),
            onPressed: onBack,
          ),
          Flexible(
            fit: FlexFit.loose,
            child: Text(
              title,
              style: TextStyle(
                color: brown,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Spacer(),
          // Trailing affordance group — chip + bookmark + tts + spread
          // toggle. mainAxisSize.min so the group only takes its
          // natural width and the Spacer above can absorb the rest.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reading-time chip — flushes every 10s, persists across
              // sessions via BookmarkStore. Surfaces both how long the
              // current session has been going AND the cumulative total
              // for this PDF.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: brown.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: brown.withOpacity(0.15), width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule, color: brown, size: 13),
                      const SizedBox(width: 4),
                      Text(
                        readingTimeLabel,
                        style: TextStyle(
                          color: brown,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Bookmark — filled ribbon when current page is bookmarked.
              IconButton(
                tooltip: isBookmarked
                    ? 'Remove bookmark'
                    : 'Bookmark this page',
                icon: Icon(
                  isBookmarked ? Icons.bookmark : Icons.bookmark_border,
                  color: brown,
                ),
                onPressed: onToggleBookmark,
              ),
              // Sticky note — opens NoteCaptureSheet (text / voice /
              // image / handwriting). Note auto-pins to this book +
              // page via currentNoteLocationProvider (already kept in
              // sync by _onPageChanged). Sits next to bookmark because
              // both are "save state about this page" actions.
              IconButton(
                tooltip: 'Sticky note (capture text / voice / image / handwriting)',
                icon: Icon(
                  Icons.sticky_note_2_outlined,
                  color: brown,
                ),
                onPressed: onAddStickyNote,
              ),
              // Read aloud — TTS. Pause icon when speaking, play icon otherwise.
              IconButton(
                tooltip: ttsPlaying ? 'Stop reading' : 'Read aloud',
                icon: Icon(
                  ttsPlaying ? Icons.stop_circle : Icons.volume_up_outlined,
                  color: brown,
                ),
                onPressed: onToggleTts,
              ),
              // Full-screen (#252). Always shows the "enter fullscreen"
              // icon here because once immersive=true, the entire _TopBar
              // is hidden by the parent — exit is via 'F' key, ESC, or
              // the floating exit pill (#268). Tooltip calls that out
              // so users don't get stranded.
              IconButton(
                tooltip: 'Full-screen (press F or ESC to exit)',
                icon: Icon(
                  isImmersive
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  color: brown,
                ),
                onPressed: onToggleImmersive,
              ),
              // Edit mode (#269). Toggles the floating
              // AnnotationToolPalette and routes touch / drag gestures
              // on the page through the AnnotationEditOverlay into
              // ShapeAnnotation / InkAnnotation records.
              IconButton(
                tooltip: isEditing ? 'Finish editing' : 'Edit (draw, highlight)',
                icon: Icon(
                  isEditing ? Icons.edit_off : Icons.edit,
                  color: isEditing
                      ? const Color(0xFF22D3EE)
                      : brown,
                ),
                onPressed: onToggleEdit,
              ),
              // Spread-mode toggle. Tap to cycle:
              //   auto → opposite-of-auto (override) → auto
              // Icon shows current resolved mode; label shows "auto" when
              // not overridden, the explicit value when overridden.
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: onToggleSpread,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          spreadMode
                              ? Icons.menu_book_sharp
                              : Icons.menu_book,
                          color: brown,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          spreadMode
                              ? (isOverridden ? '2-page (forced)' : '2-page')
                              : (isOverridden ? '1-page (forced)' : '1-page'),
                          style: TextStyle(
                            color: brown,
                            fontSize: 11,
                            fontWeight: isOverridden
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.currentPage,
    required this.totalPages,
    required this.onPrev,
    required this.onNext,
    required this.onJumpToPage,
  });
  final int currentPage;
  final int totalPages;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onJumpToPage;

  @override
  Widget build(BuildContext context) {
    // The "Page X / Y" indicator doubles as a TV-remote affordance: it's
    // wrapped in a focusable button so D-pad + OK opens the jump-to-page
    // dialog. Without this a 1036-page PDF is unreadable on TV — flipping
    // 500 pages by chevron is not a real workflow.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          _BookNavButton(
            icon: Icons.chevron_left,
            onTap: onPrev,
          ),
          Expanded(
            child: Center(
              child: _BookNavButton(
                // First-mount focus target — gives the TV remote a
                // visible landing point on entry to the BookViewer.
                // From here: D-pad left → previous chevron, right →
                // next chevron, OK → jump-to-page dialog.
                autofocus: true,
                onTap: onJumpToPage,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8,),
                  child: Text(
                    'Page ${currentPage + 1} / $totalPages',
                    style: const TextStyle(
                      color: Color(0xFF4F3017),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          _BookNavButton(
            icon: Icons.chevron_right,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

/// Focusable button used in the BookViewer bottom bar. Paints a cyan
/// ring + 1.04× scale on focus and binds D-pad OK / Enter / Space /
/// GameButtonA → ActivateIntent → onTap.
class _BookNavButton extends StatefulWidget {
  const _BookNavButton({
    required this.onTap,
    this.icon,
    this.child,
    this.autofocus = false,
  });
  final IconData? icon;
  final Widget? child;
  final VoidCallback onTap;

  /// First-mount focus target. The BookViewer passes `true` to the
  /// center "Page X / Y" button so the TV remote has somewhere
  /// visible to land on entry — D-pad left/right then reaches the
  /// chevrons; OK opens the jump-to-page dialog.
  final bool autofocus;

  @override
  State<_BookNavButton> createState() => _BookNavButtonState();
}

class _BookNavButtonState extends State<_BookNavButton> {
  bool _focused = false;
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final ringColor = _focused ? const Color(0xFF22D3EE) : Colors.transparent;
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _shortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: AnimatedScale(
        scale: _focused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ringColor, width: 2),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: ringColor.withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(8),
            child: widget.child ??
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(widget.icon, color: const Color(0xFF4F3017)),
                ),
          ),
        ),
      ),
    );
  }
}

/// Modal that prompts for a page number. Returns the entered 1-based
/// page number, or null if cancelled. Number-only keyboard; D-pad
/// navigable across the text field → Go → Cancel.
Future<int?> showJumpToPageDialog(
  BuildContext context, {
  required int totalPages,
  required int currentPage,
  String? prefilled,
}) async {
  final controller = TextEditingController(text: prefilled);
  return showDialog<int?>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Go to page'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Currently on page ${currentPage + 1} of $totalPages',
              style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, letterSpacing: 2),
              decoration: InputDecoration(
                hintText: 'e.g. 250',
                border: const OutlineInputBorder(),
                counterText: '',
              ),
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 1 && n <= totalPages) {
                  Navigator.of(ctx).pop(n);
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text);
              if (n != null && n >= 1 && n <= totalPages) {
                Navigator.of(ctx).pop(n);
              }
            },
            child: const Text('Go'),
          ),
        ],
      );
    },
  );
}
