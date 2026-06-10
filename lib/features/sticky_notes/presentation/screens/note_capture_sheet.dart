// SPDX-License-Identifier: AGPL-3.0
//
// Capture sheet — bottom sheet with four buttons (Text / Voice / Image /
// Handwriting). Each opens a capture screen tailored to its modality
// and persists to StickyNotes on save.
//
// All four flows auto-attach the current NoteLocationRef from
// currentNoteLocationProvider so notes pinned inside a BookViewer
// remember the book + page. Captures from other screens fall back to
// the contextRoute set by the entry point.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:signature/signature.dart';

import '../../data/sticky_note_repository.dart';

Future<void> showNoteCaptureSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Capture a sticky note',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 2.2,
              children: [
                _captureTile(ctx, Icons.notes,      'Text',         () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const _TextCaptureScreen(),
                  ),);
                },),
                _captureTile(ctx, Icons.mic,        'Voice',        () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const _VoiceCaptureScreen(),
                  ),);
                },),
                _captureTile(ctx, Icons.photo_camera, 'Image',      () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const _ImageCaptureScreen(),
                  ),);
                },),
                _captureTile(ctx, Icons.draw_outlined, 'Handwriting',() {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const _HandwritingCaptureScreen(),
                  ),);
                },),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _captureTile(BuildContext context, IconData icon, String label, VoidCallback onTap) {
  return Material(
    color: Theme.of(context).colorScheme.primaryContainer,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icon, size: 28, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    ),
  );
}

// ─── Common save helper ──────────────────────────────────────────────────

Future<String> _saveNote(
  WidgetRef ref, {
  required StickyNoteKind kind,
  required String id,
  String? title,
  String? body,
  String? audioPath,
  String? imagePath,
  String? handwritingPath,
  int? durationMs,
}) async {
  final loc = ref.read(currentNoteLocationProvider);
  return ref.read(stickyNoteRepositoryProvider).insert(
        id: id,
        kind: kind,
        title: title,
        body: body,
        audioPath: audioPath,
        imagePath: imagePath,
        handwritingPath: handwritingPath,
        durationMs: durationMs,
        documentId: loc.documentId,
        pageIndex: loc.pageIndex,
        scrollFraction: loc.scrollFraction,
        contextRoute: loc.contextRoute,
      );
}

// ─── 1. Text capture ─────────────────────────────────────────────────────

class _TextCaptureScreen extends ConsumerStatefulWidget {
  const _TextCaptureScreen();
  @override
  ConsumerState<_TextCaptureScreen> createState() => _TextCaptureState();
}

class _TextCaptureState extends ConsumerState<_TextCaptureScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl  = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New note'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save',
            onPressed: () async {
              final body = _bodyCtrl.text.trim();
              if (body.isEmpty) return;
              final repo = ref.read(stickyNoteRepositoryProvider);
              final slot = await repo.reserveMediaSlot(StickyNoteKind.text);
              await _saveNote(
                ref,
                kind: StickyNoteKind.text,
                id: slot.id,
                title: _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
                body: body,
              );
              if (mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Title (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _bodyCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: 'Write your note…',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 2. Voice capture ────────────────────────────────────────────────────

class _VoiceCaptureScreen extends ConsumerStatefulWidget {
  const _VoiceCaptureScreen();
  @override
  ConsumerState<_VoiceCaptureScreen> createState() => _VoiceCaptureState();
}

class _VoiceCaptureState extends ConsumerState<_VoiceCaptureScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final _titleCtrl = TextEditingController();
  bool _recording = false;
  bool _playing   = false;
  String? _path;
  int? _durationMs;
  DateTime? _startedAt;
  AudioPlayer? _player;

  @override
  void dispose() {
    _recorder.dispose();
    _titleCtrl.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) return;
    final repo = ref.read(stickyNoteRepositoryProvider);
    final slot = await repo.reserveMediaSlot(StickyNoteKind.voice);
    _path = slot.mediaPath;
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1),
      path: slot.mediaPath,
    );
    setState(() {
      _recording = true;
      _startedAt = DateTime.now();
    });
  }

  Future<void> _stop() async {
    final out = await _recorder.stop();
    setState(() {
      _recording = false;
      if (_startedAt != null) {
        _durationMs = DateTime.now().difference(_startedAt!).inMilliseconds;
      }
      if (out != null) _path = out;
    });
  }

  Future<void> _save() async {
    if (_path == null || _durationMs == null) return;
    final repo = ref.read(stickyNoteRepositoryProvider);
    final slot = await repo.reserveMediaSlot(StickyNoteKind.voice);
    // Move the file into the canonical slot (recorder may have used the
    // reserved path or a platform-default one).
    if (_path != slot.mediaPath) {
      try { await File(_path!).rename(slot.mediaPath); _path = slot.mediaPath; }
      catch (_) {/* keep original path; still works */}
    }
    await _saveNote(
      ref,
      kind: StickyNoteKind.voice,
      id: slot.id,
      title: _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
      audioPath: _path,
      durationMs: _durationMs,
    );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _preview() async {
    if (_path == null) return;
    _player ??= AudioPlayer();
    await _player!.stop();
    setState(() => _playing = true);
    await _player!.play(DeviceFileSource(_path!));
    _player!.onPlayerComplete.first.then((_) => mounted ? setState(() => _playing = false) : null);
  }

  @override
  Widget build(BuildContext context) {
    final hasRecording = _path != null && _durationMs != null && !_recording;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voice note'),
        actions: [
          if (hasRecording)
            IconButton(icon: const Icon(Icons.check), tooltip: 'Save', onPressed: _save),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Caption (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _recording ? Icons.mic : (hasRecording ? Icons.check_circle_outline : Icons.mic_none),
                      size: 96,
                      color: _recording ? Colors.red : Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    if (_recording)
                      const Text('Recording…', style: TextStyle(fontSize: 18))
                    else if (hasRecording)
                      Text('${(_durationMs! / 1000).round()}s recorded',
                          style: const TextStyle(fontSize: 18),)
                    else
                      const Text('Tap to record', style: TextStyle(fontSize: 18)),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (hasRecording)
                          ElevatedButton.icon(
                            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                            label: Text(_playing ? 'Playing…' : 'Preview'),
                            onPressed: _preview,
                          ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          icon: Icon(_recording ? Icons.stop : Icons.mic),
                          label: Text(_recording ? 'Stop' : (hasRecording ? 'Re-record' : 'Record')),
                          onPressed: _recording ? _stop : _start,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 3. Image capture ────────────────────────────────────────────────────

class _ImageCaptureScreen extends ConsumerStatefulWidget {
  const _ImageCaptureScreen();
  @override
  ConsumerState<_ImageCaptureScreen> createState() => _ImageCaptureState();
}

class _ImageCaptureState extends ConsumerState<_ImageCaptureScreen> {
  final _picker = ImagePicker();
  final _titleCtrl = TextEditingController();
  File? _imageFile;
  String? _slotPath;
  String? _slotId;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, maxWidth: 2400, imageQuality: 88);
    if (picked == null) return;
    final repo = ref.read(stickyNoteRepositoryProvider);
    final slot = await repo.reserveMediaSlot(StickyNoteKind.image);
    _slotId   = slot.id;
    _slotPath = slot.mediaPath;
    await File(picked.path).copy(slot.mediaPath);
    setState(() => _imageFile = File(slot.mediaPath));
  }

  Future<void> _save() async {
    if (_slotId == null || _slotPath == null) return;
    await _saveNote(
      ref,
      kind: StickyNoteKind.image,
      id: _slotId!,
      title: _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
      imagePath: _slotPath,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image note'),
        actions: [
          if (_imageFile != null)
            IconButton(icon: const Icon(Icons.check), tooltip: 'Save', onPressed: _save),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Caption (optional)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _imageFile == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.image_outlined, size: 96, color: Colors.grey.shade400),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 12,
                            children: [
                              FilledButton.icon(
                                icon: const Icon(Icons.photo_camera),
                                label: const Text('Camera'),
                                onPressed: () => _pick(ImageSource.camera),
                              ),
                              FilledButton.tonalIcon(
                                icon: const Icon(Icons.photo_library),
                                label: const Text('Gallery'),
                                onPressed: () => _pick(ImageSource.gallery),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(_imageFile!, fit: BoxFit.contain),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 4. Handwriting capture ──────────────────────────────────────────────

class _HandwritingCaptureScreen extends ConsumerStatefulWidget {
  const _HandwritingCaptureScreen();
  @override
  ConsumerState<_HandwritingCaptureScreen> createState() => _HandwritingCaptureState();
}

class _HandwritingCaptureState extends ConsumerState<_HandwritingCaptureScreen> {
  // signature 5.5+ made penColor a constructor-only (read-only on the
  // controller). To change colour mid-sketch we'd have to recreate the
  // controller AND copy the points across — we'll add that polish in a
  // follow-up. v1 ships with a single fixed pen colour (chosen at the
  // top of the screen, applied when the controller is built).
  Color _strokeColor = Colors.black;
  SignatureController _buildController() => SignatureController(
        penStrokeWidth: 3,
        penColor: _strokeColor,
        exportBackgroundColor: Colors.transparent,
      );
  late SignatureController _sig = _buildController();
  final _titleCtrl = TextEditingController();

  @override
  void dispose() {
    _sig.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_sig.isEmpty) return;
    final image = await _sig.toImage();
    if (image == null) return;
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final repo = ref.read(stickyNoteRepositoryProvider);
    final slot = await repo.reserveMediaSlot(StickyNoteKind.handwriting);
    await File(slot.mediaPath).writeAsBytes(bytes.buffer.asUint8List());
    await _saveNote(
      ref,
      kind: StickyNoteKind.handwriting,
      id: slot.id,
      title: _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
      handwritingPath: slot.mediaPath,
    );
    if (mounted) Navigator.pop(context);
  }

  void _setStroke(Color c) {
    if (c == _strokeColor) return;
    // signature 5.5+: penColor is read-only on the controller, so rebuild.
    // We also drop any in-progress strokes (acceptable trade-off — the
    // user explicitly picked a different colour, so they're starting over).
    setState(() {
      _strokeColor = c;
      _sig.dispose();
      _sig = _buildController();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sketch / handwriting'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Clear',
            onPressed: () => setState(() => _sig.clear()),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save',
            onPressed: _save,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: 'Caption (optional)', border: OutlineInputBorder()),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final c in const [Colors.black, Colors.red, Colors.blue, Colors.green, Colors.orange])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => _setStroke(c),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c == _strokeColor ? Colors.white : Colors.transparent,
                            width: 3,
                          ),
                          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 2)],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Signature(
                  // Keyed on stroke colour so Flutter rebuilds the
                  // Signature widget when we swap controllers — without
                  // the key the new controller is silently ignored.
                  key: ValueKey(_strokeColor.value),
                  controller: _sig,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
