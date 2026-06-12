import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
        KeyDownEvent,
        LogicalKeyboardKey,
        SystemChrome,
        SystemUiMode,
        SystemUiOverlay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../../../core/layout/responsive.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/device/device_capabilities.dart';
import '../../../../core/widgets/labeled_icon_button.dart';
import '../../../annotations/domain/entities/signature.dart' as ann;
import '../../../annotations/domain/entities/stamp.dart' as st;
import '../../../annotations/presentation/widgets/stamp_picker_sheet.dart';
import '../../../casting/presentation/providers/cast_provider.dart';
import '../../../casting/presentation/widgets/cast_button.dart';
import '../../../hotspots/data/hotspot_repository.dart';
import '../../../hotspots/domain/hotspot.dart';
import '../../../hotspots/presentation/widgets/hotspot_sheets.dart';
import '../../../lan/data/lan_repository.dart';
import '../../../lan/domain/entities.dart';
import '../../../sharing/presentation/send_to_device_sheet.dart';
import '../../../drive_sync/data/repositories/drive_repository_impl.dart';
import '../../../printing/print_fallback_sheet.dart';
import '../../../printing/print_helper.dart';
import '../../../bookmarks/presentation/add_bookmark_sheet.dart';
import '../../../bookmarks/presentation/bookmark_drawer.dart';
import '../../../bookmarks/presentation/bookmark_provider.dart';
import '../../../signatures/presentation/sign_sheet.dart';
import '../../../ai/presentation/doc_chat_sheet.dart';
import '../../../translation/presentation/widgets/translation_sheet.dart';
import '../../../voice/presentation/widgets/read_aloud_bar.dart';
import '../../data/repositories/pdf_repository_impl.dart';
import '../../domain/entities/pdf_document.dart';
import '../providers/viewer_provider.dart';
import '../sheets/pdf_tools_sheets.dart';
import '../widgets/thumbnail_sidebar.dart';
import '../widgets/viewer_toolbar.dart';

class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({required this.filePath, super.key});

  final String filePath;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  PdfViewerController _pdfController = PdfViewerController();
  final _searchController = TextEditingController();

  /// Bytes currently rendered. Re-read after every PDF mutation so
  /// SfPdfViewer doesn't serve a stale cached parse keyed by the old path.
  Uint8List? _bytes;
  bool _busy = false;
  String? _busyLabel;

  // ── Signature / stamp placement state ──────────────────────────────────
  // Either of these being non-null puts the viewer in "placement mode":
  // a draggable preview overlays the page and the user drags it before
  // tapping "Place here". Only one can be active at a time — entering
  // a new flow cancels any other in-flight placement.
  ann.SignaturePreset? _placingSignature;
  st.Stamp? _placingStamp;

  /// Position of the signature's top-left in PDF coordinate space (points,
  /// 1/72 inch). Stored in PDF coords so the preview and the committed
  /// stamp are always exactly the same size and place — converting both
  /// from viewer pixels was where the "size grows on commit" bug lived.
  Offset _placementPdfOffset = const Offset(60, 200);

  /// Size of the signature in PDF points. 180×60pt ≈ 2.5"×0.83".
  Size _placementPdfSize = const Size(180, 60);

  /// Cached page size so we can convert PDF↔viewer coords during a drag
  /// without re-reading the file every frame.
  Size? _placementPageSize;

  /// Path to a copy of the PDF made just before [_commitPlacement] writes.
  /// Tapping the Undo icon restores from this snapshot — the viewer's
  /// equivalent of an editor undo stack, scoped to "the last signature".
  String? _undoSnapshotPath;

  // ── Read aloud state ───────────────────────────────────────────────────
  // When active, [ReadAloudBar] renders below the PDF and TTS speaks
  // the user-selected text (if any), else the current page's extracted
  // text. We re-extract page text in [onPageChanged] so playback
  // continues seamlessly when the user advances pages.
  bool _readAloudActive = false;
  String _currentPageText = '';
  String? _selectedText;

  /// Stable per-document id from drift (PdfDocuments.id). We resolve it via
  /// `PdfRepository.open(...)` in [initState] so hotspot foreign keys hit a
  /// real row. Until it's loaded, the hotspot menu items are disabled.
  String? _documentUuid;

  // ── Full-screen state ───────────────────────────────────────────────────
  // Toggled by three rapid taps anywhere on the page. When on, AppBar +
  // bottom toolbar disappear, Android system UI hides via setEnabledSystemUIMode,
  // and only the PDF (plus the placement overlays for sign / stamp) remains
  // on screen. Three more taps restores everything. We use a tiny timestamp
  // window (700ms between taps) and a counter rather than a TripleTapGestureRecognizer
  // because Flutter doesn't ship one — the rolling-window approach is the
  // cleanest implementation.
  bool _fullScreen = false;
  final List<DateTime> _recentTaps = [];
  static const Duration _tripleTapWindow = Duration(milliseconds: 700);

  // ── Thumbnail sidebar state ────────────────────────────────────────────
  // Visible only on tablet-or-wider window sizes — the toggle button in
  // the AppBar shows / hides it. We default to "open" because users on a
  // tablet have plenty of horizontal room and the sidebar genuinely
  // helps navigation. Phones never see it regardless of this flag.
  bool _sidebarOpen = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _reloadBytes();
      // Resolve the drift document id so hotspots can reference it. We
      // do this lazily after bytes load so the open() upsert fires only
      // once we know the file is readable.
      try {
        final repo = await ref.read(pdfRepositoryProvider.future);
        final r = await repo.open(widget.filePath);
        r.fold(
          (doc) {
            if (mounted) setState(() => _documentUuid = doc.id);
          },
          (failure) =>
              appLogger.w('viewer: open for hotspot id failed: ${failure.message}'),
        );
      } catch (e) {
        appLogger.w('viewer: hotspot id resolution failed: $e');
      }
    });
  }

  @override
  void dispose() {
    _pdfController.dispose();
    _searchController.dispose();
    // If we leave the viewer while still in full-screen, restore the
    // OS chrome so the rest of the app doesn't inherit a hidden status
    // bar. SystemChrome state is process-global on Android.
    if (_fullScreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  /// Register a tap on the PDF area. Three taps within
  /// [_tripleTapWindow] toggles full-screen mode.
  void _onTripleTapCandidate() {
    final now = DateTime.now();
    _recentTaps.add(now);
    // Drop any tap older than the window so stale single-taps don't
    // accumulate into an accidental triple.
    _recentTaps.removeWhere((t) => now.difference(t) > _tripleTapWindow);
    if (_recentTaps.length >= 3) {
      _recentTaps.clear();
      _toggleFullScreen();
    }
  }

  /// Hide / restore AppBar + bottom toolbar + Android system chrome.
  void _toggleFullScreen() {
    setState(() => _fullScreen = !_fullScreen);
    if (_fullScreen) {
      // immersiveSticky: status bar + nav bar slide off; user can swipe
      // from the edge to reveal them temporarily, then they auto-hide.
      // Best for long-form reading.
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
  }

  Future<void> _reloadBytes() async {
    setState(() => _busy = true);
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      if (!mounted) return;
      _pdfController.dispose();
      setState(() {
        _pdfController = PdfViewerController();
        _bytes = bytes;
        _busy = false;
        _busyLabel = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Could not load PDF: $e');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _runSearch(String query) async {
    if (query.isEmpty) return;
    _pdfController.searchText(query);
  }

  /// Compact-phone search affordance — pops a bottom sheet hosting the
  /// same _searchController used by the title TextField on tablet+. Done
  /// this way (not a full search screen) so the user keeps the PDF
  /// visible behind the sheet while typing the query.
  void _showSearchSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Row(
            children: [
              const Icon(Icons.search),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search in document',
                    border: InputBorder.none,
                  ),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (q) {
                    Navigator.of(ctx).pop();
                    _runSearch(q);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Signature flow ──────────────────────────────────────────────────────

  /// Push the multi-mode signature picker, then enter placement mode so
  /// the user can drag the signature where they want it before commit.
  Future<void> _addSignatureFlow() async {
    appLogger.i('SIG: _addSignatureFlow started');
    final preset = await context.pushNamed<ann.SignaturePreset>(
      AppRoutes.signaturePad,
    );
    appLogger.i('SIG: pad returned with preset = $preset');
    if (preset == null || !mounted) return;

    // KEY: reset to a known viewport state before entering placement.
    // SfPdfViewer doesn't expose scroll offset, so when the user is
    // zoomed in / scrolled, we have no way to convert screen-space drag
    // into PDF-space coordinates correctly. Snapping to zoom=1 + page
    // top gives us a deterministic "page fills viewer width, top-left at
    // 0,0" state where the math works out exactly.
    final pageNumber = _pdfController.pageNumber;
    _pdfController.zoomLevel = 1.0;
    _pdfController.jumpToPage(pageNumber);
    // Give the viewer one frame to settle into the new state before we
    // measure the page.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    final pageIndex = (pageNumber - 1).clamp(0, 1 << 30);
    final pageSize = await _readPageSize(pageIndex);
    if (!mounted) return;

    setState(() {
      _placingSignature = preset;
      _placementPageSize = pageSize;
      // Default size: ~25% of page width, with a 3:1 aspect ratio.
      final w = pageSize.width * 0.25;
      _placementPdfSize = Size(w, w / 3);
      // Initial position: 10% in from the left, ~25% down.
      _placementPdfOffset = Offset(pageSize.width * 0.1, pageSize.height * 0.25);
    });
  }

  void _cancelPlacement() {
    setState(() {
      _placingSignature = null;
      _placingStamp = null;
      _placementPageSize = null;
    });
  }

  /// Pop the [StampPickerSheet], then enter placement mode for the chosen
  /// stamp. Mirrors [_addSignatureFlow] but renders a coloured rectangle
  /// preview instead of an image, and commits via [_commitStampPlacement].
  Future<void> _addStampFlow() async {
    final picked = await showModalBottomSheet<st.Stamp>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const StampPickerSheet(),
    );
    if (picked == null || !mounted) return;

    // Reset zoom + jump to top of current page so coord math matches the
    // committed placement (same trick as the signature flow).
    final pageNumber = _pdfController.pageNumber;
    _pdfController.zoomLevel = 1.0;
    _pdfController.jumpToPage(pageNumber);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;

    final pageIndex = (pageNumber - 1).clamp(0, 1 << 30);
    final pageSize = await _readPageSize(pageIndex);
    if (!mounted) return;

    setState(() {
      _placingSignature = null;
      _placingStamp = picked;
      _placementPageSize = pageSize;
      // Stamps are wider-than-tall; pick 35% × 8% of page by default.
      final w = pageSize.width * 0.35;
      _placementPdfSize = Size(w, w / 4.5);
      _placementPdfOffset = Offset(pageSize.width * 0.55, pageSize.height * 0.10);
    });
  }

  /// Commit the in-flight stamp at the current PDF-point rect.
  Future<void> _commitStampPlacement() async {
    final stamp = _placingStamp;
    final pageSize = _placementPageSize;
    if (stamp == null || pageSize == null) return;

    final pageNumber = _pdfController.pageNumber;
    final pageIndex = (pageNumber - 1).clamp(0, 1 << 30);
    final pdfX = _placementPdfOffset.dx.clamp(0.0, pageSize.width);
    final pdfY = _placementPdfOffset.dy.clamp(0.0, pageSize.height);
    final pdfW = _placementPdfSize.width.clamp(0.0, pageSize.width - pdfX);
    final pdfH = _placementPdfSize.height.clamp(0.0, pageSize.height - pdfY);
    final rect = Rect.fromLTWH(pdfX, pdfY, pdfW, pdfH);

    setState(() {
      _busy = true;
      _busyLabel = 'Placing stamp…';
      _placingStamp = null;
      _placementPageSize = null;
    });

    try {
      final snapshotPath = await _takeSnapshot();
      final repo = await ref.read(pdfRepositoryProvider.future);
      final docResult = await repo.open(widget.filePath);
      final doc = docResult.valueOrNull;
      if (doc == null) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
        _toast(docResult.failureOrNull?.message ?? 'Could not open PDF');
        return;
      }
      final res = await repo.placeStamp(
        doc: doc,
        pageIndex: pageIndex,
        position: rect,
        stamp: stamp,
        docName: doc.title,
      );
      if (!mounted) return;
      await res.fold(
        (_) async {
          _undoSnapshotPath = snapshotPath;
          await _reloadBytes();
          _toast('Stamp placed on page $pageNumber');
        },
        (failure) async {
          try {
            await File(snapshotPath).delete();
          } catch (_) {/* best-effort */}
          setState(() {
            _busy = false;
            _busyLabel = null;
          });
          _toast(failure.message);
        },
      );
    } catch (e, st) {
      appLogger.e('STAMP: commit exception', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Could not place stamp: $e');
    }
  }

  /// Stamp the signature using PDF-point coords directly. Both the
  /// preview and the commit derive their pixel sizes from the *same*
  /// PDF rect (see [_buildPlacementOverlay]), so what you see is what you get.
  Future<void> _commitPlacement() async {
    final preset = _placingSignature;
    final pageSize = _placementPageSize;
    if (preset == null || pageSize == null) return;

    final pageNumber = _pdfController.pageNumber;
    final pageIndex = (pageNumber - 1).clamp(0, 1 << 30);

    // Clamp inside the page bounds in case the user dragged near an edge.
    final pdfX = _placementPdfOffset.dx.clamp(0.0, pageSize.width);
    final pdfY = _placementPdfOffset.dy.clamp(0.0, pageSize.height);
    final pdfW = _placementPdfSize.width.clamp(0.0, pageSize.width - pdfX);
    final pdfH = _placementPdfSize.height.clamp(0.0, pageSize.height - pdfY);
    final rect = Rect.fromLTWH(pdfX, pdfY, pdfW, pdfH);
    appLogger.i('SIG: commit rect (pdf points) = $rect');

    setState(() {
      _busy = true;
      _busyLabel = 'Placing signature…';
      _placingSignature = null;
      _placementPageSize = null;
    });

    try {
      // Snapshot the file so Undo can restore it. One slot only — taking
      // a new signature placement overwrites the previous undo target.
      final snapshotPath = await _takeSnapshot();

      final repo = await ref.read(pdfRepositoryProvider.future);
      final docResult = await repo.open(widget.filePath);
      final doc = docResult.valueOrNull;
      if (doc == null) {
        _toast(docResult.failureOrNull?.message ?? 'Could not open PDF');
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
        return;
      }

      final placeResult = await repo.placeSignature(
        doc: doc,
        pageIndex: pageIndex,
        position: rect,
        imagePath: preset.assetPath,
      );

      if (!mounted) return;
      await placeResult.fold(
        (_) async {
          // Promote the snapshot to the active undo target only on success.
          _undoSnapshotPath = snapshotPath;
          await _reloadBytes();
          _toast('Signature placed on page $pageNumber');
          // Now offer the user a chance to save a named, retrievable copy.
          await _promptSaveSignedCopy();
        },
        (failure) async {
          // Discard the unused snapshot on failure.
          try {
            await File(snapshotPath).delete();
          } catch (_) {/* best-effort */}
          setState(() {
            _busy = false;
            _busyLabel = null;
          });
          _toast(failure.message);
        },
      );
    } catch (e, st) {
      appLogger.e('SIG: commit exception', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Could not place signature: $e');
    }
  }

  /// Ask the user whether to save the just-signed PDF as a named copy
  /// (with an optional retrieval code) into the dedicated `signed/` folder.
  /// Persists a JSON sidecar so we can list / search them later.
  Future<void> _promptSaveSignedCopy() async {
    if (!mounted) return;
    final result = await showDialog<_SignedCopyMeta>(
      context: context,
      builder: (_) => const _SaveSignedDialog(),
    );
    if (result == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Saving signed copy…';
    });
    try {
      final paths = await ref.read(appPathsProvider.future);
      final signedDir = Directory(p.join(paths.pdfDir.parent.path, 'signed'));
      if (!signedDir.existsSync()) await signedDir.create(recursive: true);

      // Strip filesystem-unsafe characters from the user's name for the
      // file path. The original name is preserved separately in metadata.
      final sanitized = result.name
          .replaceAll(RegExp(r'[^a-zA-Z0-9 _\-]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');
      final id = DateTime.now().millisecondsSinceEpoch;
      final basename = sanitized.isEmpty ? 'signed_$id' : '${sanitized}_$id';
      final destPath = p.join(signedDir.path, '$basename.pdf');
      final metaPath = p.join(signedDir.path, '$basename.json');

      await File(widget.filePath).copy(destPath);
      final meta = {
        'name': result.name,
        'code': result.code,
        'savedAt': DateTime.now().toIso8601String(),
        'sourceFile': p.basename(widget.filePath),
        'pdfPath': destPath,
      };
      await File(metaPath).writeAsString(jsonEncode(meta), flush: true);

      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast(
        result.code == null || result.code!.isEmpty
            ? 'Saved as "${result.name}"'
            : 'Saved as "${result.name}" · code ${result.code}',
      );
    } catch (e, st) {
      appLogger.e('save signed copy failed', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Could not save signed copy: $e');
    }
  }

  /// Copy the current PDF to a unique snapshot file under the app's PDF
  /// folder. Returns the snapshot path. Used for the viewer-level Undo.
  Future<String> _takeSnapshot() async {
    final paths = await ref.read(appPathsProvider.future);
    final snapshotDir = Directory(p.join(paths.pdfDir.parent.path, 'snapshots'));
    if (!snapshotDir.existsSync()) await snapshotDir.create(recursive: true);
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(snapshotDir.path, 'snapshot-$ts.pdf');
    await File(widget.filePath).copy(dest);
    return dest;
  }

  /// Replace the current PDF with the most recent snapshot, if any. Cleans
  /// up the snapshot file afterwards so subsequent edits start fresh.
  Future<void> _undoLastChange() async {
    final snapshot = _undoSnapshotPath;
    if (snapshot == null) return;
    setState(() {
      _busy = true;
      _busyLabel = 'Undoing…';
    });
    try {
      final src = File(snapshot);
      if (!src.existsSync()) {
        _toast('Snapshot missing — nothing to undo.');
        setState(() {
          _busy = false;
          _busyLabel = null;
          _undoSnapshotPath = null;
        });
        return;
      }
      final bytes = await src.readAsBytes();
      await File(widget.filePath).writeAsBytes(bytes, flush: true);
      try {
        await src.delete();
      } catch (_) {/* best-effort */}
      _undoSnapshotPath = null;
      await _reloadBytes();
      _toast('Undone.');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Undo failed: $e');
    }
  }

  /// Read just the size of one page from the file by parsing it headlessly
  /// with Syncfusion. Sized in PDF points (1/72 inch).
  Future<Size> _readPageSize(int pageIndex) async {
    final bytes = await File(widget.filePath).readAsBytes();
    final pdf = sf.PdfDocument(inputBytes: bytes);
    try {
      final s = pdf.pages[pageIndex].size;
      return Size(s.width, s.height);
    } finally {
      pdf.dispose();
    }
  }

  /// Pull the text of one page using Syncfusion's headless extractor.
  /// Returns empty string on parse error so callers can guard with a
  /// "no text on this page" toast cleanly.
  Future<String> _extractPageText(int pageIndex) async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final pdf = sf.PdfDocument(inputBytes: bytes);
      try {
        return sf.PdfTextExtractor(pdf).extractText(
          startPageIndex: pageIndex,
          endPageIndex: pageIndex,
        );
      } finally {
        pdf.dispose();
      }
    } catch (e) {
      appLogger.w('extractPageText failed: $e');
      return '';
    }
  }

  /// Upload the current PDF to Google Drive. Auto-prompts for sign-in if
  /// not already connected, then uploads to the user's "Interact Pro" folder
  /// (or whatever AppConstants.driveBackupFolderName resolves to).
  Future<void> _saveToDriveFlow() async {
    setState(() {
      _busy = true;
      _busyLabel = 'Connecting to Drive…';
    });
    try {
      final driveRepo = ref.read(driveRepositoryProvider);
      var user = await driveRepo.currentUser();
      if (user == null) {
        // Trigger sign-in flow.
        final r = await driveRepo.signIn();
        user = r.valueOrNull;
        if (user == null) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _busyLabel = null;
          });
          _toast(r.failureOrNull?.message ?? 'Drive sign-in cancelled.');
          return;
        }
      }
      if (!mounted) return;
      setState(() => _busyLabel = 'Uploading to Drive…');

      final res = await driveRepo.upload(widget.filePath);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      res.fold(
        (id) => _toast('Saved to Drive (${user!.email}).'),
        (failure) => _toast(failure.message),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Drive upload failed: $e');
    }
  }

  // ── PDF tools (merge / split / watermark) ──────────────────────────────

  /// Open the merge picker, pick N additional PDFs, then merge them with
  /// the currently-open one into a new PDF saved into the app's PDF dir.
  Future<void> _mergeFlow() async {
    final req = await showModalBottomSheet<MergeRequest>(
      context: context,
      isScrollControlled: true,
      builder: (_) => MergePicker(currentPdf: File(widget.filePath)),
    );
    if (req == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Merging ${req.files.length} PDFs…';
    });
    try {
      final repo = await ref.read(pdfRepositoryProvider.future);
      // Resolve every input through `open` so each one lands in drift
      // recents AND we get a stable PdfDocument for mergePdfs.
      final docs = <PdfDocument>[];
      for (final f in req.files) {
        final r = await repo.open(f.path);
        final d = r.valueOrNull;
        if (d == null) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _busyLabel = null;
          });
          _toast('Could not open ${f.path.split('/').last} — merge aborted.');
          return;
        }
        docs.add(d);
      }
      final res = await repo.mergePdfs(
        docs,
        outputFilename: req.outputName,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      res.fold(
        (merged) {
          ref.invalidate(allDocumentsProvider);
          _toast('Merged ${req.files.length} PDFs → ${req.outputName}');
          // Push the merged result so the user sees it immediately.
          context.pushReplacementNamed(AppRoutes.viewer, extra: merged.path);
        },
        (failure) => _toast(failure.message),
      );
    } catch (e, stk) {
      appLogger.e('merge flow failed', error: e, stackTrace: stk);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Merge failed: $e');
    }
  }

  /// Open the split dialog, parse the page-range expression, extract the
  /// chosen pages into a new PDF saved into the app's PDF dir.
  Future<void> _splitFlow() async {
    final repo = await ref.read(pdfRepositoryProvider.future);
    final docResult = await repo.open(widget.filePath);
    final doc = docResult.valueOrNull;
    if (doc == null || !mounted) {
      _toast(docResult.failureOrNull?.message ?? 'Could not open PDF');
      return;
    }
    final defaultName =
        '${p.basenameWithoutExtension(widget.filePath)}_split_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final req = await showDialog<SplitRequest>(
      context: context,
      builder: (_) => SplitDialog(
        pageCount: doc.pageCount,
        defaultOutputName: defaultName,
      ),
    );
    if (req == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Splitting…';
    });
    final res = await repo.extractPages(
      doc,
      req.pages1Based.map((n) => n - 1).toList(),
      outputFilename: req.outputName,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyLabel = null;
    });
    res.fold(
      (split) {
        ref.invalidate(allDocumentsProvider);
        _toast('Extracted ${req.pages1Based.length} pages → ${req.outputName}');
        context.pushReplacementNamed(AppRoutes.viewer, extra: split.path);
      },
      (failure) => _toast(failure.message),
    );
  }

  /// Open the watermark sheet, apply the chosen text or image to every
  /// page of the current PDF in place. Snapshot first so the AppBar's
  /// undo can revert if the user dislikes the result.
  Future<void> _watermarkFlow() async {
    final req = await showModalBottomSheet<WatermarkRequest>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const WatermarkSheet(),
    );
    if (req == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyLabel = 'Adding watermark to every page…';
    });
    try {
      final snapshotPath = await _takeSnapshot();
      final repo = await ref.read(pdfRepositoryProvider.future);
      final docResult = await repo.open(widget.filePath);
      final doc = docResult.valueOrNull;
      if (doc == null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
        _toast(docResult.failureOrNull?.message ?? 'Could not open PDF');
        return;
      }

      final res = await repo.addWatermark(
        doc: doc,
        text: req.text,
        imagePath: req.imagePath,
        opacity: req.opacity,
        rotationDegrees: req.rotationDegrees,
        fontSize: req.fontSize,
      );
      if (!mounted) return;
      await res.fold(
        (_) async {
          // Promote snapshot to undo target only on success — same
          // pattern as signature/stamp placement.
          _undoSnapshotPath = snapshotPath;
          await _reloadBytes();
          _toast('Watermark applied to every page');
        },
        (failure) async {
          try {
            await File(snapshotPath).delete();
          } catch (_) {/* best-effort */}
          setState(() {
            _busy = false;
            _busyLabel = null;
          });
          _toast(failure.message);
        },
      );
    } catch (e, stk) {
      appLogger.e('watermark flow failed', error: e, stackTrace: stk);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyLabel = null;
      });
      _toast('Watermark failed: $e');
    }
  }

  // ── Hotspot flow ────────────────────────────────────────────────────────

  /// Open the create-hotspot sheet, then drop the new hotspot at the
  /// center of the current page. Coordinates use PDF points (1/72").
  /// Drag-to-place placement (like signatures) is a follow-up — for now
  /// the user can long-press the hotspot in the list sheet to delete and
  /// re-create at a different page.
  Future<void> _addHotspotFlow() async {
    final docId = _documentUuid;
    if (docId == null) {
      _toast('PDF still loading — try again in a moment.');
      return;
    }
    final draft = await showModalBottomSheet<HotspotDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const HotspotCreateSheet(),
    );
    if (draft == null || !mounted) return;

    final pageNumber = _pdfController.pageNumber;
    final pageIndex = (pageNumber - 1).clamp(0, 1 << 30);
    final pageSize = await _readPageSize(pageIndex);

    // Roughly 30% wide × 8% tall, centered. Big enough to long-press, small
    // enough not to overlap multiple paragraphs.
    final w = pageSize.width * 0.30;
    final h = pageSize.height * 0.08;
    final left = (pageSize.width - w) / 2.0;
    final top = (pageSize.height - h) / 2.0;
    final payload = switch (draft.kind) {
      HotspotKind.note => NotePayload(draft.content),
      HotspotKind.link => LinkPayload(draft.content),
      HotspotKind.image => ImagePayload(draft.content),
      HotspotKind.audio => AudioPayload(draft.content),
    };
    final hotspot = Hotspot(
      id: '',
      documentUuid: docId,
      pageNumber: pageNumber,
      kind: draft.kind,
      bounds: [left, top, left + w, top + h],
      payload: payload,
      createdAt: DateTime.now(),
    );
    final res = await ref.read(hotspotRepositoryProvider).add(hotspot);
    if (!mounted) return;
    res.fold(
      (_) => _toast('Hotspot pinned to page $pageNumber'),
      (failure) => _toast(failure.message),
    );
  }

  /// Open the list sheet showing every hotspot in the current document.
  /// Tapping the "Jump to page" action navigates the viewer there.
  void _showHotspotsList() {
    final docId = _documentUuid;
    if (docId == null) {
      _toast('PDF still loading — try again in a moment.');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => HotspotListSheet(
        documentUuid: docId,
        onJumpToPage: (pageNumber) => _pdfController.jumpToPage(pageNumber),
      ),
    );
  }

  /// Chat-with-document (market-fit Gate B). Opens the AI sheet bound to the
  /// current file + page; the sheet extracts text and calls pro-api.
  Future<void> _askAiFlow() async {
    final page = _pdfController.pageNumber;
    await DocChatSheet.show(
      context,
      filePath: widget.filePath,
      currentPage: page < 1 ? 1 : page,
      onUpgrade: () => context.pushNamed(AppRoutes.paywall),
    );
  }

  /// Open the TranslationSheet over the user-selected text if any, else
  /// the current page's extracted text. Pre-fills the sheet's "original
  /// text" so the user can immediately pick a target language and hit
  /// Translate.
  Future<void> _translateFlow() async {
    final pageIndex = (_pdfController.pageNumber - 1).clamp(0, 1 << 30);
    var text = _selectedText?.trim() ?? '';
    if (text.isEmpty) {
      text = await _extractPageText(pageIndex);
    }
    if (!mounted) return;
    if (text.trim().isEmpty) {
      _toast(
        'No text to translate. Run OCR first if the PDF is a scan.',
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TranslationSheet(originalText: text),
    );
  }

  /// Show or hide the read-aloud bar. On show, extract the current page
  /// text. Toasts if the page is text-less (e.g. a scanned image PDF —
  /// run OCR first to make it readable).
  Future<void> _toggleReadAloud() async {
    if (_readAloudActive) {
      setState(() => _readAloudActive = false);
      return;
    }
    final pageIndex = (_pdfController.pageNumber - 1).clamp(0, 1 << 30);
    final text = await _extractPageText(pageIndex);
    if (!mounted) return;
    if (text.trim().isEmpty) {
      _toast(
        'No text on this page to read aloud. '
        'Run OCR first if the PDF is a scan.',
      );
      return;
    }
    setState(() {
      _readAloudActive = true;
      _currentPageText = text;
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(viewerModeProvider);
    // On compact (phone) windows we cannot fit a search TextField title
    // + 10 action icons in the AppBar — some icons overflowed off the
    // right edge ("not visible" report 2026-05-13). On compact: title
    // becomes the file name (Text), search moves into an action icon
    // that pops a search bottom sheet, and only the most-used actions
    // stay in the top bar — the rest live in the existing More menu
    // (which also gets Stroke / Stamp / Edit-in-editor / Sign /
    // approve entries added below so nothing disappears).
    final isCompact = WindowSize.of(context).isCompact;

    return Scaffold(
      // AppBar + toolbar disappear in full-screen so only the PDF
      // remains visible. Three taps on the page area toggles back.
      appBar: _fullScreen
          ? null
          : AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              title: isCompact
                  ? Text(
                      p.basenameWithoutExtension(widget.filePath),
                      overflow: TextOverflow.ellipsis,
                    )
                  : TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: 'Search in document',
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: _runSearch,
                    ),
              actions: [
                // Compact-only: search icon that pops a tiny sheet so
                // the user can still hit Enter to search in the PDF.
                if (isCompact)
                  LabeledIconButton(
                    icon: const Icon(Icons.search),
                    label: 'Find',
                    tooltip: 'Search in document',
                    onPressed: () => _showSearchSheet(context),
                  ),
                  LabeledIconButton(
                    icon: const Icon(Icons.auto_awesome),
                    label: 'Ask AI',
                    tooltip: 'Ask this document (summarize, extract, translate)',
                    onPressed: _askAiFlow,
                  ),
                // Undo only appears when there's a snapshot to roll back to —
                // currently that means "the last signature placement". Easy to
                // extend later for other one-shot mutations.
                if (_undoSnapshotPath != null)
                  LabeledIconButton(
                    icon: const Icon(Icons.undo),
                    label: 'Undo',
                    tooltip: 'Undo last change',
                    onPressed: _busy ? null : _undoLastChange,
                  ),
                // "Stroke" = handwritten signature drawn on the page
                // (legacy signature feature). Distinct from the new
                // cryptographic "Sign" button below (task #3 audit
                // trail with Ed25519 + visible stamp). Worth keeping
                // both — they serve different purposes (visual
                // signature vs. tamper-evident approval). On phones
                // these three are hidden from the top bar and the
                // user reaches them via the More menu — the bottom
                // ViewerToolbar also exposes Sign / Stamp / Edit as
                // mode toggles, so the affordance isn't lost.
                if (!isCompact) ...[
                  LabeledIconButton(
                    icon: const Icon(Icons.draw_outlined),
                    label: 'Stroke',
                    tooltip: 'Add handwritten signature',
                    onPressed: _addSignatureFlow,
                  ),
                  LabeledIconButton(
                    icon: const Icon(Icons.approval_outlined),
                    label: 'Stamp',
                    tooltip: 'Add stamp',
                    onPressed: _addStampFlow,
                  ),
                  LabeledIconButton(
                    icon: const Icon(Icons.edit),
                    label: 'Edit',
                    tooltip: 'Open in editor',
                    onPressed: () => context.pushNamed(
                      AppRoutes.editor,
                      extra: widget.filePath,
                    ),
                  ),
                ],
                CastButton(
                  pdfPath: widget.filePath,
                  documentTitle: p.basenameWithoutExtension(widget.filePath),
                  currentPage: ref.watch(currentPageProvider),
                  // 0 = "unknown" — the LAN cast endpoint lazily computes
                  // the page count from pdfx on first request, so leaving
                  // this at 0 is harmless. The viewer doesn't expose
                  // total-pages as a provider yet; if it ever needs to,
                  // wire one in viewer_provider.dart and read it here.
                  totalPages: 0,
                ),
                // "Send to nearby device" — pushes the open PDF to
                // another Interact Pro instance on the same Wi-Fi via
                // Bonsoir mDNS (lib/features/lan/). Separate from the
                // Cast icon (left of this) because Cast targets dumb
                // receivers (AirPlay / Chromecast); Send targets other
                // Interact Pro phones / TVs.
                //
                // Before 2026-05-12 this button pushed the Nearby
                // Devices SCREEN via go_router, which yanked the
                // navigator stack out from under any open CastSheet
                // mid-animation (the "cast half-closed" symptom). Now
                // it opens SendToDeviceSheet as a sibling modal — same
                // bottom-sheet lifecycle as CastSheet, so the two
                // never tangle.
                //
                // Pairing setup still lives at Settings → Nearby
                // Devices; this button is the per-document send path.
                // Hidden on compact phones — reached via the More menu
                // ("Send to nearby device") to free top-bar space.
                if (!isCompact)
                  LabeledIconButton(
                    icon: const Icon(Icons.devices),
                    label: 'Send',
                    tooltip: 'Send to nearby Interact Pro device',
                    onPressed: () {
                    // Guard: if Cast is mid-session OR a sheet is
                    // already animating, defer so the modal stack
                    // doesn't fight itself. Cheap check via cast
                    // session provider — null/inactive means safe.
                    final session = ref
                        .read(castSessionProvider)
                        .asData
                        ?.value;
                    if (session?.isActive == true) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Stop the current cast session before '
                            'sending the file to another device.',
                          ),
                        ),
                      );
                      return;
                    }
                    SendToDeviceSheet.show(
                      context,
                      file: File(widget.filePath),
                      kind: ShareKind.pdf,
                      suggestedName: p.basename(widget.filePath),
                    );
                  },
                ),
                // Bookmark — flag the current page with a colored marker
                // and optional note. Tapping opens the add-bookmark
                // bottom sheet (task #1). Long-press could later open
                // the bookmark drawer directly; for now we expose both
                // via separate menu entries in the More menu.
                Consumer(builder: (context, ref, _) {
                  final countAsync = ref.watch(
                    bookmarkCountProvider(widget.filePath),
                  );
                  final count = countAsync.maybeWhen(
                    data: (n) => n,
                    orElse: () => 0,
                  );
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      LabeledIconButton(
                        icon: const Icon(Icons.bookmark_border),
                        label: 'Bookmark',
                        tooltip: count == 0
                            ? 'Add bookmark'
                            : 'Bookmarks ($count)',
                        onPressed: () async {
                          // Long-press / count > 0: show drawer first.
                          // Tap: jump straight to the add-bookmark
                          // sheet so the most common path (flag this
                          // page) is one tap.
                          final added = await showAddBookmarkSheet(
                            context,
                            documentId: widget.filePath,
                            pageIndex: ref.read(currentPageProvider),
                          );
                          if (added && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Bookmark added · '
                                  'page ${ref.read(currentPageProvider) + 1}',
                                ),
                                action: SnackBarAction(
                                  label: 'View all',
                                  onPressed: () async {
                                    final pageToJump =
                                        await showBookmarkDrawer(
                                      context,
                                      documentId: widget.filePath,
                                      documentTitle:
                                          p.basenameWithoutExtension(
                                              widget.filePath,),
                                    );
                                    if (pageToJump != null &&
                                        context.mounted) {
                                      // pdfViewerController.jumpToPage
                                      // would go here; see Phase 2.
                                    }
                                  },
                                ),
                              ),
                            );
                          }
                        },
                      ),
                      if (count > 0)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1,),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            constraints: const BoxConstraints(minWidth: 16),
                            child: Text(
                              count > 99 ? '99+' : '$count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  );
                },),
                // Sign / approve — tap opens SignSheet (Phase 1: creates
                // audit row + writes sidecar JSON in Phase 2). Long-press
                // jumps straight to the verification screen showing the
                // signature chain on the current PDF. See task #3. On
                // compact phones the entry moves to the More menu so the
                // top bar fits.
                if (!isCompact)
                GestureDetector(
                  onLongPress: () {
                    context.pushNamed(
                      AppRoutes.verifySignatures,
                      extra: <String, String>{
                        'documentId': widget.filePath,
                        'pdfPath': widget.filePath,
                        'documentTitle':
                            p.basenameWithoutExtension(widget.filePath),
                      },
                    );
                  },
                  child: LabeledIconButton(
                    icon: const Icon(Icons.gesture),
                    label: 'Sign',
                    tooltip: 'Sign / approve (long-press: view chain)',
                    onPressed: () async {
                      final docId = widget.filePath;
                      final result = await showSignSheet(
                        context,
                        documentId: docId,
                        pdfPath: widget.filePath,
                        // Stamp lands on the page the user is currently
                        // viewing (Phase 2.5 default placement).
                        pageIndex: ref.read(currentPageProvider),
                      );
                      if (result != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Signed — code ${result.shortCode}',
                            ),
                            action: SnackBarAction(
                              label: 'View chain',
                              onPressed: () => context.pushNamed(
                                AppRoutes.verifySignatures,
                                extra: <String, String>{
                                  'documentId': widget.filePath,
                                  'pdfPath': widget.filePath,
                                  'documentTitle': p
                                      .basenameWithoutExtension(widget.filePath),
                                },
                              ),
                            ),
                            duration: const Duration(seconds: 6),
                          ),
                        );
                      }
                    },
                  ),
                ),
                if (WindowSize.of(context).isTabletOrWider)
                  LabeledIconButton(
                    icon: Icon(_sidebarOpen
                        ? Icons.view_sidebar
                        : Icons.view_sidebar_outlined,),
                    label: 'Pages',
                    tooltip: _sidebarOpen
                        ? 'Hide page thumbnails'
                        : 'Show page thumbnails',
                    onPressed: () =>
                        setState(() => _sidebarOpen = !_sidebarOpen),
                  ),
                LabeledIconButton(
                  icon: const Icon(Icons.fullscreen),
                  label: 'Full',
                  tooltip: 'Full-screen (or triple-tap the page)',
                  onPressed: _toggleFullScreen,
                ),
                LabeledIconButton(
                  icon: const Icon(Icons.more_vert),
                  label: 'More',
                  tooltip: 'More',
                  onPressed: () => _showOverflow(context),
                ),
              ],
            ),
      body: Focus(
        autofocus: true,
        // TV remote D-pad + keyboard nav. Without this, arrow keys do
        // nothing on TVs / Chromebooks / desktop and the user is stuck
        // tapping the screen — which a TV remote can't do.
        //   ← / Page Up      → previous page
        //   → / Page Down    → next page
        //   Space            → next page (matches macOS Preview)
        //   Home / End       → first / last page
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final pageCount = _pdfController.pageCount;
          if (pageCount == 0) return KeyEventResult.ignored;
          final current = _pdfController.pageNumber;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.pageUp) {
            if (current > 1) _pdfController.previousPage();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
              event.logicalKey == LogicalKeyboardKey.pageDown ||
              event.logicalKey == LogicalKeyboardKey.space) {
            if (current < pageCount) _pdfController.nextPage();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.home) {
            _pdfController.firstPage();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.end) {
            _pdfController.lastPage();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Column(
        children: [
          if (!_fullScreen)
            ViewerToolbar(
              tool: mode,
              onChanged: (m) {
                // Sign + Stamp are one-shot actions, not persistent modes.
                // Tapping them invokes the corresponding flow immediately;
                // the toolbar's selected tool stays unchanged. Other tools
                // (select, highlight, edit) still toggle as state.
                if (m == ViewerTool.sign) {
                  _addSignatureFlow();
                  return;
                }
                if (m == ViewerTool.stamp) {
                  _addStampFlow();
                  return;
                }
                ref.read(viewerModeProvider.notifier).state = m;
              },
            ),
          Expanded(
            child: Row(
              children: [
                // Page thumbnail sidebar — tablets only, toggleable, and
                // hidden in full-screen mode (the user wants every pixel
                // of the PDF in that mode).
                if (!_fullScreen &&
                    _sidebarOpen &&
                    WindowSize.of(context).isTabletOrWider)
                  ThumbnailSidebar(
                    pdfPath: widget.filePath,
                    currentPage: ref.watch(currentPageProvider),
                    onPageSelected: (pageNumber) {
                      _pdfController.jumpToPage(pageNumber);
                    },
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewerSize =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return Stack(
                  children: [
                    if (_bytes == null)
                      const Center(child: CircularProgressIndicator())
                    else
                      // Disable viewer scrolling while placing so the
                      // overlay's pan gestures don't fight with the PDF
                      // scroll. The viewer is still visible underneath.
                      AbsorbPointer(
                        absorbing: _placingSignature != null || _placingStamp != null,
                        child: SfPdfViewer.memory(
                          _bytes!,
                          key: ValueKey(
                            'viewer-${_bytes!.length}-'
                            '${_bytes!.isNotEmpty ? _bytes!.first : 0}-'
                            '${_bytes!.isNotEmpty ? _bytes!.last : 0}',
                          ),
                          controller: _pdfController,
                          // Single-page layout = predictable geometry. The
                          // page is centered with letterbox margins, no
                          // continuous scroll between pages, no padding
                          // gap above the page top. We can compute the
                          // exact page rect within the viewer.
                          pageLayoutMode: PdfPageLayoutMode.single,
                          canShowScrollHead: true,
                          canShowScrollStatus: true,
                          enableDoubleTapZooming:
                              _placingSignature == null && _placingStamp == null,
                          onPageChanged: (details) async {
                            ref.read(currentPageProvider.notifier).state =
                                details.newPageNumber;
                            // Push the new page to any live cast session.
                            // No-op when nothing is being mirrored (the
                            // service short-circuits if its session isn't
                            // active), so this is safe to call every time.
                            //
                            // Don't await — page-flip latency on the
                            // viewer should be unaffected by Cast SDK
                            // round-trips (Chromecast LoadMedia can take
                            // 500ms+ over slow Wi-Fi).
                            unawaited(ref
                                .read(castServiceProvider)
                                .setActivePage(details.newPageNumber),);
                            // Keep TTS in sync with whatever page is on screen.
                            if (_readAloudActive) {
                              final t = await _extractPageText(
                                details.newPageNumber - 1,
                              );
                              if (mounted) {
                                setState(() => _currentPageText = t);
                              }
                            }
                          },
                          // Track user text selection so "Read aloud"
                          // and "Translate" can prefer the selection
                          // over the whole page.
                          onTextSelectionChanged: (details) {
                            setState(() {
                              _selectedText = details.selectedText;
                            });
                          },
                        ),
                      ),
                    if (_placingSignature != null || _placingStamp != null)
                      _buildPlacementOverlay(viewerSize),
                    if (_busy)
                      ColoredBox(
                        color: const Color(0x66000000),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              if (_busyLabel != null) ...[
                                const SizedBox(height: 12),
                                Text(
                                  _busyLabel!,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    // Triple-tap detector — translucent overlay that just
                    // catches taps without blocking pinch/scroll. We use
                    // `behavior: translucent` so single taps still pass
                    // through to SfPdfViewer for text selection. The
                    // window is 700ms across three taps.
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _onTripleTapCandidate,
                      ),
                    ),
                    // Subtle hint shown briefly the first few seconds in
                    // full-screen so the user remembers how to exit. Just
                    // a small floating chip top-center; auto-fades on
                    // first interaction.
                    if (_fullScreen)
                      const Positioned(
                        top: 24,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Material(
                            color: Colors.black54,
                            shape: StadiumBorder(),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              child: Text(
                                'Triple-tap to exit full-screen',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
                ),
              ],
            ),
          ),
          // Read-aloud control bar — sits above the BottomNav-equivalent
          // (none here) so it stays visible while the user scrolls. Has a
          // close button on the right to dismiss.
          if (_readAloudActive)
            Row(
              children: [
                Expanded(
                  child: ReadAloudBar(
                    textForCurrentPage: _currentPageText,
                    selectedText: _selectedText,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Stop reading',
                  onPressed: _toggleReadAloud,
                ),
              ],
            ),
        ],
      ),
      ),
    );
  }

  /// Draggable signature preview + commit/cancel bar. Coordinates and
  /// sizes are stored in PDF points; the overlay converts to viewer
  /// pixels using a letterbox-aware scale so the preview matches the
  /// eventual committed size 1:1, *including offsets*.
  ///
  /// Single-page layout + zoom=1 means the page is fit-to-viewport with
  /// `BoxFit.contain` semantics: scaled by min(W,H) ratios, centered.
  /// We mirror that math here.
  Widget _buildPlacementOverlay(Size viewerSize) {
    final pageSize = _placementPageSize!;
    final preset = _placingSignature;
    final stamp = _placingStamp;
    final isStamp = stamp != null;

    final scaleW = viewerSize.width / pageSize.width;
    final scaleH = viewerSize.height / pageSize.height;
    final pxPerPt = scaleW < scaleH ? scaleW : scaleH;

    // Page rendered rect within the viewer (centered with letterbox).
    final pageRenderedW = pageSize.width * pxPerPt;
    final pageRenderedH = pageSize.height * pxPerPt;
    final pageOffsetX = (viewerSize.width - pageRenderedW) / 2.0;
    final pageOffsetY = (viewerSize.height - pageRenderedH) / 2.0;

    // PDF coords → viewer pixels (with letterbox offset).
    final left = pageOffsetX + _placementPdfOffset.dx * pxPerPt;
    final top = pageOffsetY + _placementPdfOffset.dy * pxPerPt;
    final width = _placementPdfSize.width * pxPerPt;
    final height = _placementPdfSize.height * pxPerPt;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _cancelPlacement,
            child: const ColoredBox(color: Color(0x33000000)),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                // Convert pixel-space drag delta back into PDF points.
                final dx = details.delta.dx / pxPerPt;
                final dy = details.delta.dy / pxPerPt;
                final next = _placementPdfOffset + Offset(dx, dy);
                _placementPdfOffset = Offset(
                  next.dx.clamp(0.0, pageSize.width - _placementPdfSize.width),
                  next.dy.clamp(0.0, pageSize.height - _placementPdfSize.height),
                );
              });
            },
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                border: Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              padding: const EdgeInsets.all(4),
              child: isStamp
                  ? _StampPreview(stamp: stamp)
                  : Image.file(File(preset!.assetPath), fit: BoxFit.contain),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(28),
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Cancel',
                    onPressed: _cancelPlacement,
                  ),
                  const Expanded(
                    child: Text(
                      'Drag to position.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  // Size picker — three presets, expressed as fraction of
                  // page width so they look consistent across paper sizes.
                  PopupMenuButton<double>(
                    icon: const Icon(Icons.aspect_ratio),
                    tooltip: 'Size',
                    onSelected: (frac) => setState(() {
                      final w = pageSize.width * frac;
                      _placementPdfSize = Size(w, w / 3);
                    }),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 0.18, child: Text('Small')),
                      PopupMenuItem(value: 0.25, child: Text('Medium')),
                      PopupMenuItem(value: 0.40, child: Text('Large')),
                    ],
                  ),
                  FilledButton(
                    onPressed: isStamp ? _commitStampPlacement : _commitPlacement,
                    child: const Text('Place here'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showOverflow(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      // Allow the sheet to grow up to ~85% of screen height; without this
      // iOS pins it to ~half the screen and a 9-item Column overflows on
      // anything smaller than an iPhone Pro Max.
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            ListTile(
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('Run OCR on this PDF'),
              subtitle: const Text(
                'Extract selectable text — works on scans and photos.',
              ),
              onTap: () {
                Navigator.pop(context);
                // Pass the active PDF path so the OCR screen can run
                // immediately without an extra file-picker step.
                context.pushNamed(
                  AppRoutes.ocr,
                  extra: widget.filePath,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.merge_outlined),
              title: const Text('Merge with another PDF'),
              subtitle: const Text(
                'Combine this PDF with one or more others into a new file.',
              ),
              onTap: () {
                Navigator.pop(context);
                _mergeFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_split),
              title: const Text('Split PDF (extract pages)'),
              subtitle: const Text(
                'Pick a page range like "1-5, 8" → save as a new PDF.',
              ),
              onTap: () {
                Navigator.pop(context);
                _splitFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.water_drop_outlined),
              title: const Text('Add watermark to every page'),
              subtitle: const Text(
                'CONFIDENTIAL / DRAFT / your name, or an image overlay.',
              ),
              onTap: () {
                Navigator.pop(context);
                _watermarkFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.draw_outlined),
              title: const Text('Add signature'),
              subtitle: const Text(
                'Draw with finger or Apple Pencil, pick a photo, or reuse a saved one.',
              ),
              onTap: () {
                Navigator.pop(context);
                _addSignatureFlow();
              },
            ),
            // Cryptographic Sign / approve — mirrors the top-bar Sign
            // button on tablet+; the only entry point on compact phones.
            // Different from "Add signature" above (visual stroke) — this
            // creates the Ed25519 audit-trail row + sidecar JSON.
            ListTile(
              leading: const Icon(Icons.gesture),
              title: const Text('Sign / approve'),
              subtitle: const Text(
                'Cryptographic signature with audit trail — tap to sign, view chain after.',
              ),
              onTap: () async {
                Navigator.pop(context);
                final result = await showSignSheet(
                  context,
                  documentId: widget.filePath,
                  pdfPath: widget.filePath,
                  pageIndex: ref.read(currentPageProvider),
                );
                if (result != null && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Signed — code ${result.shortCode}'),
                      action: SnackBarAction(
                        label: 'View chain',
                        onPressed: () => context.pushNamed(
                          AppRoutes.verifySignatures,
                          extra: <String, String>{
                            'documentId': widget.filePath,
                            'pdfPath': widget.filePath,
                            'documentTitle':
                                p.basenameWithoutExtension(widget.filePath),
                          },
                        ),
                      ),
                      duration: const Duration(seconds: 6),
                    ),
                  );
                }
              },
            ),
            // Open in editor — was top-bar "Edit" icon on tablet+; the
            // only entry point on compact phones now. Different from the
            // bottom ViewerToolbar's "Edit" mode toggle (which sets a
            // selection mode); this jumps to the standalone editor.
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Open in editor'),
              subtitle: const Text(
                'Full edit mode — rearrange, rotate, delete pages.',
              ),
              onTap: () {
                Navigator.pop(context);
                context.pushNamed(AppRoutes.editor, extra: widget.filePath);
              },
            ),
            ListTile(
              leading: const Icon(Icons.approval_outlined),
              title: const Text('Add stamp'),
              subtitle: const Text(
                'APPROVED, REJECTED, custom text, or your own image.',
              ),
              onTap: () {
                Navigator.pop(context);
                _addStampFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('Translate'),
              subtitle: Text(
                _selectedText != null && _selectedText!.trim().isNotEmpty
                    ? 'Translate selection (Pro)'
                    : 'Translate this page (Pro)',
              ),
              onTap: () {
                Navigator.pop(context);
                _translateFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.record_voice_over),
              title: Text(_readAloudActive ? 'Stop reading' : 'Read aloud'),
              subtitle: const Text('Reads the current page out loud (Pro)'),
              onTap: () {
                Navigator.pop(context);
                _toggleReadAloud();
              },
            ),
            ListTile(
              leading: const Icon(Icons.print_outlined),
              title: const Text('Print'),
              subtitle: const Text(
                'Uses the system print sheet — Wi-Fi printers appear automatically.',
              ),
              onTap: () async {
                Navigator.pop(context);
                final pdfFile = File(widget.filePath);
                final ok = await PrintHelper.printPdf(pdfFile: pdfFile);
                // Use context.mounted (not State.mounted) so Dart's flow
                // analysis unblocks the subsequent context use — the
                // lint `use_build_context_synchronously` keys off the
                // BuildContext check specifically.
                if (!context.mounted) return;
                if (ok) return; // job actually sent
                // Print sheet was cancelled OR no printer was found.
                // Either way, surface the fallback sheet so the user
                // gets one tap to Drive / Share / Save copy.
                await showPrintFallbackSheet(
                  context: context,
                  pdfFile: pdfFile,
                  onSaveToDrive: _saveToDriveFlow,
                  failureReason:
                      'No printer? Save or share instead.',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.devices_other),
              title: const Text('Send to nearby device'),
              subtitle: const Text(
                'Direct LAN transfer to your other paired devices.',
              ),
              onTap: () {
                Navigator.pop(context);
                _showSendToNearby();
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Save to Drive'),
              subtitle: const Text(
                'Backs up the current PDF to your Google Drive.',
              ),
              onTap: () {
                Navigator.pop(context);
                _saveToDriveFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_location_alt_outlined),
              title: const Text('Add hotspot'),
              subtitle: const Text(
                'Pin a note or link to the current page (Pro).',
              ),
              enabled: _documentUuid != null,
              onTap: () {
                Navigator.pop(context);
                _addHotspotFlow();
              },
            ),
            ListTile(
              leading: const Icon(Icons.location_searching),
              title: const Text('Show hotspots'),
              subtitle: const Text(
                'List every hotspot in this document, jump or delete.',
              ),
              enabled: _documentUuid != null,
              onTap: () {
                Navigator.pop(context);
                _showHotspotsList();
              },
            ),
            // Share via OS share-sheet — works on phone/tablet, not on
            // TV (Android TV has no share targets installed by default,
            // tap produces "no app to handle this" error). Hidden on TV
            // unless user toggled "Show advanced controls" in Settings.
            CapabilityGate.share(
              child: ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () async {
                  Navigator.pop(context);
                  await PrintHelper.sharePdf(pdfFile: File(widget.filePath));
                },
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }

  /// Picks one of the paired LAN devices and ships the active PDF to it.
  Future<void> _showSendToNearby() async {
    final picked = await showModalBottomSheet<NearbyDevice>(
      context: context,
      builder: (sheetCtx) {
        return Consumer(
          builder: (consumerCtx, ref, _) {
            final discovered = ref.watch(discoveredDevicesProvider);
            return SafeArea(
              child: discovered.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Discovery error: $e'),
                ),
                data: (peers) {
                  final paired = peers.where((p) => p.isPaired).toList();
                  if (paired.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'No paired devices on this Wi-Fi.\n'
                            'Open Settings → Nearby Devices to pair one.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: () {
                              Navigator.of(sheetCtx).pop();
                              context.pushNamed(AppRoutes.nearbyDevices);
                            },
                            child: const Text('Open Nearby Devices'),
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: paired
                        .map(
                          (p) => ListTile(
                            leading: const Icon(Icons.devices),
                            title: Text(p.name),
                            subtitle: Text('${p.platform} · ${p.host}'),
                            onTap: () => Navigator.of(sheetCtx).pop(p),
                          ),
                        )
                        .toList(),
                  );
                },
              ),
            );
          },
        );
      },
    );
    if (picked == null || !mounted) return;

    final repo = await ref.read(lanRepositoryProvider.future);
    final res = await repo.send(peer: picked, file: File(widget.filePath));
    if (!mounted) return;
    res.fold(
      (_) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent to ${picked.name}')),
      ),
      (failure) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.message)),
      ),
    );
  }
}

/// In-overlay preview that mimics the rendered stamp: coloured border,
/// bold uppercase text, opacity-modulated. Matches what
/// [PdfRepositoryImpl.placeStamp] actually draws on the PDF.
class _StampPreview extends StatelessWidget {
  const _StampPreview({required this.stamp});
  final st.Stamp stamp;

  @override
  Widget build(BuildContext context) {
    if (stamp.kind == st.StampKind.image && stamp.imagePath != null) {
      return Opacity(
        opacity: stamp.opacity,
        child: Image.file(File(stamp.imagePath!), fit: BoxFit.contain),
      );
    }
    return Opacity(
      opacity: stamp.opacity,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: stamp.color, width: 3),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              stamp.text,
              style: TextStyle(
                color: stamp.color,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tiny record-style holder for what the Save Signed Copy dialog returns.
class _SignedCopyMeta {
  const _SignedCopyMeta({required this.name, this.code});
  final String name;
  final String? code;
}

/// Two-field dialog: name (required, identifying label) + optional code
/// (a short reference, like "INV-2025-04" or a 4-digit PIN). Returns null
/// if the user cancels.
class _SaveSignedDialog extends StatefulWidget {
  const _SaveSignedDialog();

  @override
  State<_SaveSignedDialog> createState() => _SaveSignedDialogState();
}

class _SaveSignedDialogState extends State<_SaveSignedDialog> {
  final _nameCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  String? _nameError;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Name is required');
      return;
    }
    final code = _codeCtrl.text.trim();
    Navigator.of(context).pop(
      _SignedCopyMeta(name: name, code: code.isEmpty ? null : code),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save signed copy'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Bayer Settlement',
              errorText: _nameError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_nameError != null) setState(() => _nameError = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeCtrl,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Code (optional)',
              hintText: 'e.g. INV-2025-04 or 1234',
              helperText: 'Use later to find this signed PDF.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Skip'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
