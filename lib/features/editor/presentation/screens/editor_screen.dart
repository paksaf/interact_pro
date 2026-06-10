import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../domain/entities/edit_action.dart';
import '../providers/editor_controller.dart';
import '../widgets/voice_text_note_sheet.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({required this.filePath, super.key});
  final String filePath;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  PdfViewerController _pdfController = PdfViewerController();

  /// Bytes currently rendered by the viewer. Re-read from disk after every
  /// successful edit so we bypass Syncfusion's path-keyed native cache —
  /// `SfPdfViewer.file(File(samePath))` returns the cached parse on iOS,
  /// which is why "Delete page" appeared to do nothing in the first cut.
  /// Memory mode forces a re-parse.
  Uint8List? _bytes;
  bool _loadingBytes = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _reloadBytes();
      // Hand the document off to EditorController so apply() / undo() know
      // which file they're operating on.
      final repo = await ref.read(pdfRepositoryProvider.future);
      final r = await repo.open(widget.filePath);
      r.fold(
        ref.read(editorControllerProvider.notifier).setDocument,
        (failure) => _toast(failure.message),
      );
    });
  }

  @override
  void dispose() {
    _pdfController.dispose();
    super.dispose();
  }

  /// Re-read the file and replace the controller. Replacing the controller
  /// is what guarantees the viewer's *internal* page cache is wiped — a
  /// shared controller across SfPdfViewer instances reuses the parsed doc.
  Future<void> _reloadBytes() async {
    setState(() => _loadingBytes = true);
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      if (!mounted) return;
      _pdfController.dispose();
      setState(() {
        _pdfController = PdfViewerController();
        _bytes = bytes;
        _loadingBytes = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBytes = false);
      _toast('Could not reload PDF: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 0-indexed current page. SfPdfViewer reports 1-indexed via
  /// [PdfViewerController.pageNumber].
  int get _currentPageIndex => (_pdfController.pageNumber - 1).clamp(0, 1 << 30);

  // ── Tool handlers ───────────────────────────────────────────────────────

  Future<void> _rotateCurrentPage() async {
    final degrees = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rotate page'),
        content: const Text('Pick the rotation to apply to the current page.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, 90), child: const Text('90° ↻')),
          TextButton(onPressed: () => Navigator.pop(ctx, 180), child: const Text('180°')),
          TextButton(onPressed: () => Navigator.pop(ctx, 270), child: const Text('90° ↺')),
        ],
      ),
    );
    if (degrees == null) return;

    // Snapshot the page's rotation *before* the action runs. We pass it
    // along so undo can restore exactly this value without inverse math
    // (Syncfusion's rotation getter has been observed returning stale data
    // after a save+reopen cycle, which broke undo when we tried to invert
    // via -degrees).
    final previousRotation = await _readPageRotation(_currentPageIndex);

    final ctrl = ref.read(editorControllerProvider.notifier);
    await ctrl.apply(RotatePage(
      pageIndex: _currentPageIndex,
      timestamp: DateTime.now(),
      degrees: degrees,
      previousRotation: previousRotation,
    ),);
    _afterApply('Page rotated $degrees°');
  }

  /// Read the current rotation of [pageIndex] in degrees by opening the
  /// PDF on disk via Syncfusion's headless API. We trust this getter only
  /// at click-time, never across save/reopen cycles.
  Future<int> _readPageRotation(int pageIndex) async {
    try {
      final bytes = await File(widget.filePath).readAsBytes();
      final pdf = sf.PdfDocument(inputBytes: bytes);
      final r = pdf.pages[pageIndex].rotation;
      pdf.dispose();
      return switch (r) {
        sf.PdfPageRotateAngle.rotateAngle90 => 90,
        sf.PdfPageRotateAngle.rotateAngle180 => 180,
        sf.PdfPageRotateAngle.rotateAngle270 => 270,
        _ => 0,
      };
    } catch (_) {
      return 0; // Defensive — degrades to additive math in repo.apply.
    }
  }

  Future<void> _deleteCurrentPage() async {
    final doc = ref.read(editorControllerProvider).document;
    if (doc == null || doc.pageCount <= 1) {
      _toast('Cannot delete the only page.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this page?'),
        content: Text('Page ${_pdfController.pageNumber} will be removed. '
            'This is undoable from the editor.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final ctrl = ref.read(editorControllerProvider.notifier);
    await ctrl.apply(DeletePage(
      pageIndex: _currentPageIndex,
      timestamp: DateTime.now(),
    ),);
    _afterApply('Page deleted');
  }

  /// Opens the voice/text note sheet, then inserts whatever the user
  /// typed or dictated as an [InsertText] edit action on the current page.
  ///
  /// Default placement: 1" margin from the top-left of the page, 14pt
  /// helvetica, black. The action goes through the editor's undo stack so
  /// the user can roll it back from the AppBar's undo button.
  Future<void> _addTextOrVoiceNote() async {
    final result = await showModalBottomSheet<VoiceTextNoteResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const VoiceTextNoteSheet(),
    );
    if (result == null || !mounted) return;

    final ctrl = ref.read(editorControllerProvider.notifier);
    await ctrl.apply(InsertText(
      pageIndex: _currentPageIndex,
      timestamp: DateTime.now(),
      text: result.text,
      // 72pt = 1 inch margin from top-left, leaving room for the bounding
      // box that drawString uses internally.
      position: const Offset(72, 72),
      fontSize: 14,
      color: const Color(0xFF000000),
      fontFamily: 'Helvetica',
    ),);
    _afterApply('Note added to page ${_pdfController.pageNumber}');
  }

  Future<void> _flattenDocument() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Flatten this PDF?'),
        content: const Text(
          'Flattening renders every page as an image. Annotations bake in, '
          'text becomes non-selectable, and edits can no longer be undone. '
          'Useful before sharing a final version.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Flatten'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final doc = ref.read(editorControllerProvider).document;
    if (doc == null) return;

    // Flatten goes through PdfRepository directly (not EditAction) because
    // it's an irreversible whole-document operation.
    final repo = await ref.read(pdfRepositoryProvider.future);
    final r = await repo.flatten(doc);
    if (!mounted) return;
    await r.fold(
      (newDoc) async {
        ref.read(editorControllerProvider.notifier).setDocument(newDoc);
        await _reloadBytes();
        _toast('PDF flattened');
      },
      (failure) async => _toast(failure.message),
    );
  }

  /// Refresh the viewer + update document reference after a successful edit.
  Future<void> _afterApply(String successMessage) async {
    if (!mounted) return;
    final state = ref.read(editorControllerProvider);
    if (state.error != null) {
      _toast(state.error!);
      return;
    }
    await _reloadBytes();
    _toast(successMessage);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final EditorState state = ref.watch(editorControllerProvider);
    final EditorController ctrl = ref.read(editorControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit PDF'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: state.canUndo && !state.isApplying
                ? () async {
                    await ctrl.undo();
                    _afterApply('Undone');
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            onPressed: state.canRedo && !state.isApplying
                ? () async {
                    await ctrl.redo();
                    _afterApply('Redone');
                  }
                : null,
          ),
          TextButton(
            onPressed: state.isApplying ? null : () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_bytes == null)
            const Center(child: CircularProgressIndicator())
          else
            SfPdfViewer.memory(
              _bytes!,
              // Hash the bytes' length+first/last bytes for a cheap key —
              // forces a fresh widget tree whenever the file content
              // changes, which sidesteps Syncfusion's internal PDF cache.
              key: ValueKey(
                'viewer-${_bytes!.length}-'
                '${_bytes!.isNotEmpty ? _bytes!.first : 0}-'
                '${_bytes!.isNotEmpty ? _bytes!.last : 0}',
              ),
              controller: _pdfController,
            ),
          if (state.isApplying || _loadingBytes)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: <Widget>[
            _Tool(
              icon: Icons.text_fields,
              label: 'Text / Voice',
              onTap: state.isApplying ? null : _addTextOrVoiceNote,
            ),
            _Tool(
              icon: Icons.image_outlined,
              label: 'Image',
              onTap: () => _toast('Image insertion — coming soon.'),
            ),
            _Tool(
              icon: Icons.crop_rotate,
              label: 'Rotate',
              onTap: state.isApplying ? null : _rotateCurrentPage,
            ),
            _Tool(
              icon: Icons.delete_outline,
              label: 'Delete page',
              onTap: state.isApplying ? null : _deleteCurrentPage,
            ),
            _Tool(
              icon: Icons.layers_outlined,
              label: 'Flatten',
              onTap: state.isApplying ? null : _flattenDocument,
            ),
          ],
        ),
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled ? Theme.of(context).disabledColor : null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}
