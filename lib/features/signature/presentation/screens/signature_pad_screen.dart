import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:signature/signature.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/logger.dart';
import '../../../annotations/domain/entities/signature.dart' as ann;

/// Multi-mode signature picker.
///
/// **Three sources** the user can pick from:
///   1. **Draw** — finger or Apple Pencil on a white canvas. Apple Pencil is
///      automatically detected by the underlying `signature` package and gets
///      pressure / tilt — no extra setup.
///   2. **From photo** — pick an existing image (e.g. a phone-camera shot of
///      a paper signature). Stored as-is for v1; future iterations will run
///      threshold + edge cleanup so the white background drops to transparent.
///   3. **Saved** — list of signatures previously created on this device,
///      sourced from the on-disk `signatures/` folder.
///
/// In all three cases the result is a [ann.SignaturePreset] popped back to
/// the caller (the Viewer's "Add signature" overflow item) which then drives
/// placement onto the active PDF page.
class SignaturePadScreen extends ConsumerStatefulWidget {
  const SignaturePadScreen({super.key});

  @override
  ConsumerState<SignaturePadScreen> createState() =>
      _SignaturePadScreenState();
}

class _SignaturePadScreenState extends ConsumerState<SignaturePadScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Where saved signature PNGs live on disk. Resolved lazily because
  /// `appPathsProvider` is a FutureProvider.
  Future<Directory> _signaturesDir() async {
    final paths = await ref.read(appPathsProvider.future);
    final dir = Directory(p.join(paths.pdfDir.parent.path, 'signatures'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add signature'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.draw), text: 'Draw'),
            Tab(icon: Icon(Icons.photo_outlined), text: 'Photo'),
            Tab(icon: Icon(Icons.history), text: 'Saved'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _DrawTab(signaturesDir: _signaturesDir),
          _PhotoTab(signaturesDir: _signaturesDir),
          _SavedTab(signaturesDir: _signaturesDir),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Draw — finger / Apple Pencil
// ─────────────────────────────────────────────────────────────────────────

class _DrawTab extends ConsumerStatefulWidget {
  const _DrawTab({required this.signaturesDir});
  final Future<Directory> Function() signaturesDir;

  @override
  ConsumerState<_DrawTab> createState() => _DrawTabState();
}

class _DrawTabState extends ConsumerState<_DrawTab> {
  late SignatureController _controller;
  Color _penColor = Colors.black;
  double _penWidth = 3;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = _newController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  SignatureController _newController() => SignatureController(
        penStrokeWidth: _penWidth,
        penColor: _penColor,
        exportBackgroundColor: Colors.transparent,
      );

  void _rebuildController() {
    _controller.dispose();
    _controller = _newController();
    setState(() {});
  }

  Future<void> _save() async {
    appLogger.i('SIG-PAD: Draw _save invoked, isEmpty=${_controller.isEmpty}');
    if (_controller.isEmpty) {
      _toast('Sign somewhere first.');
      return;
    }
    setState(() => _saving = true);
    try {
      final Uint8List? png = await _controller.toPngBytes();
      appLogger.i('SIG-PAD: toPngBytes returned ${png?.length} bytes');
      if (png == null) throw StateError('Failed to render signature.');
      final preset = await _persistPng(
        ref: ref,
        bytes: png,
        kind: ann.SignatureKind.drawn,
        signaturesDir: widget.signaturesDir,
      );
      appLogger.i('SIG-PAD: persisted at ${preset.assetPath}, popping');
      if (!mounted) return;
      context.pop<ann.SignaturePreset>(preset);
    } catch (e, st) {
      appLogger.e('SIG-PAD: save failed', error: e, stackTrace: st);
      if (mounted) _toast('Could not save signature: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Stack(
              children: [
                Signature(
                  controller: _controller,
                  backgroundColor: Colors.transparent,
                ),
                const Positioned(
                  bottom: 12,
                  left: 12,
                  right: 12,
                  child: IgnorePointer(child: Divider(thickness: 1)),
                ),
                const Positioned(
                  bottom: 16,
                  left: 16,
                  child: IgnorePointer(
                    child: Text('Sign here — finger or Apple Pencil',
                        style: TextStyle(color: Colors.grey, fontSize: 12),),
                  ),
                ),
              ],
            ),
          ),
        ),
        _DrawToolbar(
          penColor: _penColor,
          penWidth: _penWidth,
          onColorChanged: (c) {
            _penColor = c;
            _rebuildController();
          },
          onWidthChanged: (w) {
            _penWidth = w;
            _rebuildController();
          },
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _controller.isNotEmpty ? () => _controller.clear() : null,
                    child: const Text('Clear'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Use this signature'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DrawToolbar extends StatelessWidget {
  const _DrawToolbar({
    required this.penColor,
    required this.penWidth,
    required this.onColorChanged,
    required this.onWidthChanged,
  });

  final Color penColor;
  final double penWidth;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onWidthChanged;

  static const _palette = [Colors.black, Colors.blue, Colors.red, Colors.green];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              const Text('Color'),
              const SizedBox(width: 12),
              ..._palette.map(
                (c) => GestureDetector(
                  onTap: () => onColorChanged(c),
                  child: Container(
                    margin: const EdgeInsets.only(right: 8),
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        width: penColor == c ? 3 : 1,
                        color: penColor == c
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Text('Width'),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 8,
                  value: penWidth,
                  onChanged: onWidthChanged,
                ),
              ),
              Text(penWidth.toStringAsFixed(1)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Photo — pick an image (e.g. paper signature scanned with the camera)
// ─────────────────────────────────────────────────────────────────────────

class _PhotoTab extends ConsumerStatefulWidget {
  const _PhotoTab({required this.signaturesDir});
  final Future<Directory> Function() signaturesDir;

  @override
  ConsumerState<_PhotoTab> createState() => _PhotoTabState();
}

class _PhotoTabState extends ConsumerState<_PhotoTab> {
  Uint8List? _previewBytes;
  String? _sourceName;
  bool _saving = false;

  Future<void> _pick() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final file = res?.files.first;
    if (file == null || file.path == null) return;
    final bytes = await File(file.path!).readAsBytes();
    setState(() {
      _previewBytes = bytes;
      _sourceName = file.name;
    });
  }

  Future<void> _save() async {
    if (_previewBytes == null) return;
    setState(() => _saving = true);
    try {
      final preset = await _persistPng(
        ref: ref,
        bytes: _previewBytes!,
        kind: ann.SignatureKind.imported,
        signaturesDir: widget.signaturesDir,
        suggestedName: _sourceName,
      );
      if (!mounted) return;
      context.pop<ann.SignaturePreset>(preset);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: _previewBytes == null
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.photo_library_outlined,
                            size: 80,
                            color: Theme.of(context).colorScheme.outline,),
                        const SizedBox(height: 16),
                        const Text(
                          'Pick a photo of your signature on paper, or any '
                          'image you want to use.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _pick,
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: const Text('Pick image'),
                        ),
                      ],
                    ),
                  )
                : Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: Theme.of(context).dividerColor),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Image.memory(_previewBytes!, fit: BoxFit.contain),
                  ),
          ),
        ),
        if (_previewBytes != null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : _pick,
                      child: const Text('Pick different image'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Use this image'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Saved — list previous signatures from the on-disk signatures/ folder
// ─────────────────────────────────────────────────────────────────────────

class _SavedTab extends ConsumerStatefulWidget {
  const _SavedTab({required this.signaturesDir});
  final Future<Directory> Function() signaturesDir;

  @override
  ConsumerState<_SavedTab> createState() => _SavedTabState();
}

class _SavedTabState extends ConsumerState<_SavedTab> {
  late Future<List<File>> _filesFuture;

  @override
  void initState() {
    super.initState();
    _filesFuture = _loadFiles();
  }

  Future<List<File>> _loadFiles() async {
    final dir = await widget.signaturesDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.png'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  Future<void> _pickFile(File f) async {
    final preset = ann.SignaturePreset(
      id: p.basenameWithoutExtension(f.path),
      name: 'Saved · ${p.basenameWithoutExtension(f.path).substring(0, 8)}',
      kind: ann.SignatureKind.drawn,
      assetPath: f.path,
      createdAt: f.statSync().modified,
    );
    if (!mounted) return;
    context.pop<ann.SignaturePreset>(preset);
  }

  Future<void> _delete(File f) async {
    try {
      await f.delete();
      if (!mounted) return;
      setState(() => _filesFuture = _loadFiles());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<File>>(
      future: _filesFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snap.data!;
        if (files.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history,
                      size: 80,
                      color: Theme.of(context).colorScheme.outline,),
                  const SizedBox(height: 16),
                  const Text(
                    'No saved signatures yet. Use the Draw or Photo tabs '
                    'to create one — it will appear here next time.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisExtent: 140,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          itemCount: files.length,
          itemBuilder: (_, i) {
            final f = files[i];
            return InkWell(
              onTap: () => _pickFile(f),
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: Theme.of(context).dividerColor),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Image.file(f, fit: BoxFit.contain),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _delete(f),
                      tooltip: 'Delete',
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Shared persistence helper
// ─────────────────────────────────────────────────────────────────────────

/// Writes [bytes] into the signatures dir as a PNG and returns the
/// matching [ann.SignaturePreset]. Used by both Draw and Photo tabs so
/// they end up in the same on-disk catalogue.
Future<ann.SignaturePreset> _persistPng({
  required WidgetRef ref,
  required Uint8List bytes,
  required ann.SignatureKind kind,
  required Future<Directory> Function() signaturesDir,
  String? suggestedName,
}) async {
  final dir = await signaturesDir();
  final id = const Uuid().v4();
  final file = File(p.join(dir.path, '$id.png'));
  await file.writeAsBytes(bytes, flush: true);
  return ann.SignaturePreset(
    id: id,
    name: suggestedName ??
        'Signature ${DateTime.now().toIso8601String().substring(0, 10)}',
    kind: kind,
    assetPath: file.path,
    createdAt: DateTime.now(),
  );
}
