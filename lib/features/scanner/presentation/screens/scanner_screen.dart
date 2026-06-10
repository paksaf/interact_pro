import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../../core/permissions/app_permissions.dart';
import '../../../../core/permissions/permission_dialog.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../core/storage/app_database.dart' as db;
import '../../../../core/storage/app_paths.dart';
import '../../../code_scanner/presentation/widgets/code_generator_view.dart';
import '../../../code_scanner/presentation/widgets/code_scanner_view.dart';
import '../../../code_scanner/presentation/widgets/saved_codes_view.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/presentation/providers/viewer_provider.dart';
import '../../domain/repositories/scanner_repository.dart';
import '../../data/repositories/scanner_repository_impl.dart';

// ignore: unused_import — kept for the FilePicker types referenced in
// "open existing PDF as scan" once the user wires it in.

/// Top-level mode toggle. Each mode is its own widget tree so switching
/// is cheap and we don't have to share state across them.
enum _ScanMode { document, code, generate, history }

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  _ScanMode _mode = _ScanMode.document;

  // Document-mode state.
  List<String> _pages = const [];
  ScanFilter _filter = ScanFilter.magicColor;
  bool _building = false;

  // Code-scan mode state.
  bool _continuous = false;

  Future<void> _scan() async {
    final granted = await ensurePermission(
      context: context,
      request: AppPermissions.requestCamera,
      featureLabel: 'Camera',
      reason: 'Scanning a document needs camera access to capture pages.',
    );
    if (!granted || !mounted) return;

    final repo = ref.read(scannerRepositoryProvider);
    final res = await repo.capturePages();
    if (!mounted) return;
    res.fold((pages) => setState(() => _pages = pages), (f) => _snack(f.message));
  }

  Future<void> _save() async {
    if (_pages.isEmpty) return;
    setState(() => _building = true);
    final repo = ref.read(scannerRepositoryProvider);
    final res = await repo.buildPdf(imagePaths: _pages, filter: _filter);
    if (!mounted) return;
    setState(() => _building = false);
    await res.fold(
      (path) async {
        try {
          final pdfRepo = await ref.read(pdfRepositoryProvider.future);
          await pdfRepo.open(path);
          ref.invalidate(allDocumentsProvider);
        } catch (_) {/* best-effort */}
        if (!mounted) return;
        _snack('Saved: ${path.split('/').last}');
        context.pushReplacementNamed(AppRoutes.viewer, extra: path);
      },
      (f) async => _snack(f.message),
    );
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  /// Hand a generated/saved code's PNG into the user's most likely next
  /// step: drop it onto a PDF as a stamp. If they have an open PDF in
  /// recents we route them through the picker; otherwise we offer to
  /// pick a PDF first.
  Future<void> _useCodeAsStamp(String imagePath, String label) async {
    if (!File(imagePath).existsSync()) {
      _snack('Image file is missing — try regenerating.');
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final pdfPath = picked?.files.single.path;
    if (pdfPath == null || !mounted) return;

    // Copy into the PDF dir + index, mirroring the home-screen import flow.
    final paths = await ref.read(appPathsProvider.future);
    final targetPath = paths.pdfPathFor(p.basename(pdfPath));
    if (pdfPath != targetPath) {
      try {
        await File(pdfPath).copy(targetPath);
      } catch (_) {/* fall through with original path */}
    }
    final pdfRepo = await ref.read(pdfRepositoryProvider.future);
    await pdfRepo.open(targetPath);
    ref.invalidate(allDocumentsProvider);

    if (!mounted) return;
    // Hand off to the viewer, then prompt the user that a stamp image
    // is queued — they tap "Add stamp" → Image tab and the same path
    // is right there. The viewer's stamp flow already supports image
    // stamps via the picker's file chooser; we surface the path via a
    // toast-with-action so they can copy it if needed.
    context.pushNamed(AppRoutes.viewer, extra: targetPath);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tap "Add stamp" → Image to use "$label".'),
          duration: const Duration(seconds: 6),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan'),
        actions: [
          if (_mode == _ScanMode.code)
            IconButton(
              icon: Icon(_continuous ? Icons.repeat_on : Icons.repeat),
              tooltip: _continuous
                  ? 'Continuous mode on'
                  : 'Continuous mode off',
              onPressed: () => setState(() => _continuous = !_continuous),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<_ScanMode>(
              segments: const [
                ButtonSegment(
                  value: _ScanMode.document,
                  icon: Icon(Icons.description_outlined, size: 18),
                  label: Text('Document', style: TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: _ScanMode.code,
                  icon: Icon(Icons.qr_code_scanner, size: 18),
                  label: Text('Read', style: TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: _ScanMode.generate,
                  icon: Icon(Icons.qr_code_2, size: 18),
                  label: Text('Generate', style: TextStyle(fontSize: 12)),
                ),
                ButtonSegment(
                  value: _ScanMode.history,
                  icon: Icon(Icons.history, size: 18),
                  label: Text('History', style: TextStyle(fontSize: 12)),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
          Expanded(
            child: switch (_mode) {
              _ScanMode.document => _buildDocumentMode(context),
              _ScanMode.code => _buildCodeMode(context),
              _ScanMode.generate => _buildGenerateMode(context),
              _ScanMode.history => _buildHistoryMode(context),
            },
          ),
        ],
      ),
      floatingActionButton: _mode == _ScanMode.document
          ? FloatingActionButton(
              onPressed: _scan,
              // TV remote D-pad lands here on entry — only one focusable
              // target on this screen until the user picks pages.
              autofocus: true,
              child: const Icon(Icons.camera_alt),
            )
          : null,
    );
  }

  // ── Document mode ─────────────────────────────────────────────────────

  Widget _buildDocumentMode(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        // Hint banner — makes multi-page book scanning discoverable. The
        // underlying CunningDocumentScanner already supports adding many
        // pages in one capture session (tap the + button inside its UI),
        // and tap-the-FAB-again here adds further batches. Without this
        // banner users assumed it was single-page only.
        if (_pages.isEmpty)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.tertiaryContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.menu_book, size: 20, color: cs.onTertiaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Scanning a book?',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: cs.onTertiaryContainer,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap the camera, then keep adding pages inside the scanner. '
                        'When done, tap "Save as PDF" — every page becomes one '
                        'searchable PDF in your library.',
                        style: TextStyle(
                          color: cs.onTertiaryContainer,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedButton<ScanFilter>(
            segments: const [
              ButtonSegment(value: ScanFilter.magicColor, label: Text('Magic')),
              ButtonSegment(value: ScanFilter.photo, label: Text('Photo')),
              ButtonSegment(value: ScanFilter.grayscale, label: Text('Gray')),
              ButtonSegment(value: ScanFilter.blackAndWhite, label: Text('B&W')),
            ],
            selected: {_filter},
            onSelectionChanged: (s) => setState(() => _filter = s.first),
          ),
        ),
        // Page count + add-more affordance — prominent so book-scanning
        // users know they're accumulating pages and can keep going.
        if (_pages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.layers, size: 18, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  '${_pages.length} page${_pages.length == 1 ? '' : 's'} captured',
                  style: TextStyle(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.add_a_photo, size: 18),
                  label: const Text('Add more pages'),
                ),
              ],
            ),
          ),
        Expanded(
          child: _pages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.document_scanner_outlined,
                          size: 80, color: Theme.of(context).colorScheme.outline,),
                      const SizedBox(height: 16),
                      const Text('No pages yet — tap the camera to start'),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.7,
                  ),
                  itemCount: _pages.length,
                  itemBuilder: (_, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(_pages[i]), fit: BoxFit.cover),
                  ),
                ),
        ),
        if (_pages.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              icon: _building
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),)
                  : const Icon(Icons.save),
              label: Text(_building
                  ? 'Saving…'
                  : 'Save ${_pages.length}-page PDF',),
              onPressed: _building ? null : _save,
            ),
          ),
      ],
    );
  }

  // ── Read mode (camera-based code scanner) ─────────────────────────────

  Widget _buildCodeMode(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CodeScannerView(
          key: ValueKey('code-scanner-$_continuous'),
          continuous: _continuous,
        ),
      ),
    );
  }

  // ── Generate mode ─────────────────────────────────────────────────────

  Widget _buildGenerateMode(BuildContext context) {
    return CodeGeneratorView(
      onSaved: (result) {
        // Surface a "Use as stamp" follow-up so the user can immediately
        // drop the generated PNG onto a PDF.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved ${result.format} · ${result.rawValue}'),
            action: SnackBarAction(
              label: 'Use as stamp',
              onPressed: () => _useCodeAsStamp(
                result.imagePath,
                result.rawValue,
              ),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      },
    );
  }

  // ── History mode ──────────────────────────────────────────────────────

  Widget _buildHistoryMode(BuildContext context) {
    return SavedCodesView(
      onUseAsStamp: (db.SavedCode code) {
        final imagePath = code.imagePath;
        if (imagePath == null || imagePath.isEmpty) return;
        _useCodeAsStamp(imagePath, code.label ?? code.rawValue);
      },
    );
  }
}
