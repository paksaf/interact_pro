// SPDX-License-Identifier: AGPL-3.0
//
// Note detail / edit. Shows the full media (audio with play button,
// image at full size, handwriting at full size, text in a textarea),
// plus title + tags + color picker. Tapping save updates the row;
// tapping pin toggles pinned; tapping delete archives.

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/app_database.dart';
import '../../data/sticky_note_repository.dart';

class NoteDetailScreen extends ConsumerStatefulWidget {
  const NoteDetailScreen({super.key, required this.noteId});
  final String noteId;
  @override
  ConsumerState<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends ConsumerState<NoteDetailScreen> {
  final _titleCtrl = TextEditingController();
  final _bodyCtrl  = TextEditingController();
  String _color = 'yellow';
  bool _loaded = false;
  AudioPlayer? _player;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final note = await ref.read(stickyNoteRepositoryProvider).findById(widget.noteId);
    if (!mounted || note == null) return;
    _titleCtrl.text = note.title ?? '';
    _bodyCtrl.text  = note.body  ?? '';
    _color          = note.color;
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final repo = ref.read(stickyNoteRepositoryProvider);
    final noteAsync = ref.watch(stickyNotesProvider(
      const StickyNoteFilter(),
    ));
    // We don't actually need the list — but watching it keeps us reactive
    // to pin/archive changes from the long-press menu in the grid.
    // Get the current row directly:
    return FutureBuilder(
      future: repo.findById(widget.noteId),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final note = snap.data;
        if (note == null) {
          return const Scaffold(body: Center(child: Text('Note not found.')));
        }
        // Suppress unused-warn — we use noteAsync only for reactive triggers.
        // ignore: unused_local_variable
        final _ = noteAsync;
        final kind = StickyNoteKind.fromDbValue(note.kind);
        return Scaffold(
          appBar: AppBar(
            title: Text(_kindLabel(kind)),
            actions: [
              IconButton(
                icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                tooltip: note.pinned ? 'Unpin' : 'Pin',
                onPressed: () async {
                  await repo.togglePinned(note.id, !note.pinned);
                  setState(() {});
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Move to trash',
                onPressed: () async {
                  await repo.archive(note.id);
                  if (mounted) Navigator.pop(context);
                },
              ),
              IconButton(
                icon: const Icon(Icons.check),
                tooltip: 'Save',
                onPressed: () async {
                  await repo.updateBody(
                    note.id,
                    title: _titleCtrl.text.trim().isEmpty ? null : _titleCtrl.text.trim(),
                    body:  _bodyCtrl.text.trim().isEmpty  ? null : _bodyCtrl.text.trim(),
                    color: _color,
                  );
                  if (mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (kind != StickyNoteKind.text)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _media(note, kind),
                ),
              TextField(
                controller: _titleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bodyCtrl,
                minLines: 3,
                maxLines: 12,
                decoration: InputDecoration(
                  labelText: kind == StickyNoteKind.text ? 'Note' : 'Caption',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: stickyColors
                    .map((c) => ChoiceChip(
                          label: const SizedBox(width: 28, height: 4),
                          selected: _color == c,
                          backgroundColor: _bgColor(c),
                          selectedColor:   _bgColor(c),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: BorderSide(
                              color: _color == c ? Colors.black : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          onSelected: (_) => setState(() => _color = c),
                        ),)
                    .toList(),
              ),
              const SizedBox(height: 24),
              if (note.documentId != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.book_outlined),
                    title: const Text('Captured in book'),
                    subtitle: note.pageIndex == null
                        ? const Text('Page unknown')
                        : Text('Page ${note.pageIndex! + 1}'),
                  ),
                ),
              if (note.contextRoute != null && note.documentId == null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.location_on_outlined),
                    title: const Text('Captured from'),
                    subtitle: Text(note.contextRoute!),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _media(StickyNote n, StickyNoteKind kind) {
    switch (kind) {
      case StickyNoteKind.image:
        return n.imagePath != null && File(n.imagePath!).existsSync()
            ? ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(File(n.imagePath!)),
              )
            : const Text('(image missing)');
      case StickyNoteKind.handwriting:
        return n.handwritingPath != null && File(n.handwritingPath!).existsSync()
            ? ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  color: Colors.white,
                  child: Image.file(File(n.handwritingPath!)),
                ),
              )
            : const Text('(handwriting missing)');
      case StickyNoteKind.voice:
        final secs = ((n.durationMs ?? 0) / 1000).round();
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _bgColor(_color),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              IconButton.filled(
                icon: const Icon(Icons.play_arrow),
                iconSize: 32,
                onPressed: () async {
                  _player ??= AudioPlayer();
                  if (n.audioPath != null) {
                    await _player!.stop();
                    await _player!.play(DeviceFileSource(n.audioPath!));
                  }
                },
              ),
              const SizedBox(width: 12),
              Text('${secs}s recording',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),),
            ],
          ),
        );
      case StickyNoteKind.text:
        return const SizedBox.shrink();
    }
  }

  static String _kindLabel(StickyNoteKind k) => switch (k) {
        StickyNoteKind.text        => 'Note',
        StickyNoteKind.voice       => 'Voice note',
        StickyNoteKind.image       => 'Image note',
        StickyNoteKind.handwriting => 'Sketch',
      };

  static Color _bgColor(String c) => switch (c) {
        'yellow' => const Color(0xFFFFF59D),
        'pink'   => const Color(0xFFF8BBD0),
        'green'  => const Color(0xFFC8E6C9),
        'blue'   => const Color(0xFFBBDEFB),
        'purple' => const Color(0xFFE1BEE7),
        'grey'   => const Color(0xFFE0E0E0),
        _        => const Color(0xFFFFF59D),
      };
}
