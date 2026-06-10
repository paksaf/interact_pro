// SPDX-License-Identifier: AGPL-3.0
//
// One sticky note in the grid. Paper-style background, type badge,
// location ref, optional pinned indicator. Long-press = multi-select;
// tap = open detail/edit; tap-and-hold on the audio waveform = quick
// play without leaving the grid (handled in NotesScreen).

import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/storage/app_database.dart';
import '../../data/sticky_note_repository.dart';

class StickyNoteCard extends StatelessWidget {
  const StickyNoteCard({
    super.key,
    required this.note,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final StickyNote note;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final kind = StickyNoteKind.fromDbValue(note.kind);
    final bg = _bgColor(note.color);
    final fg = _fgColor(note.color);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      shadowColor: Colors.black26,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: selected ? Border.all(color: fg, width: 2.5) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _typeBadge(kind, fg),
                  const Spacer(),
                  if (note.pinned)
                    Icon(Icons.push_pin, size: 16, color: fg.withOpacity(0.7)),
                ],
              ),
              const SizedBox(height: 8),
              if (note.title != null && note.title!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    note.title!,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              _content(kind, fg),
              const SizedBox(height: 8),
              _locationRow(context, fg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeBadge(StickyNoteKind kind, Color fg) {
    final (icon, label) = switch (kind) {
      StickyNoteKind.text        => (Icons.notes,       'Note'),
      StickyNoteKind.voice       => (Icons.mic,         'Voice'),
      StickyNoteKind.image       => (Icons.image,       'Image'),
      StickyNoteKind.handwriting => (Icons.draw,        'Sketch'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: fg.withOpacity(0.7)),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: fg.withOpacity(0.7),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _content(StickyNoteKind kind, Color fg) {
    switch (kind) {
      case StickyNoteKind.text:
        return Text(
          note.body ?? '',
          style: TextStyle(color: fg, fontSize: 13, height: 1.35),
          maxLines: 6,
          overflow: TextOverflow.ellipsis,
        );
      case StickyNoteKind.voice:
        final secs = ((note.durationMs ?? 0) / 1000).round();
        return Row(
          children: [
            Icon(Icons.graphic_eq, color: fg.withOpacity(0.7)),
            const SizedBox(width: 8),
            Text(
              '${secs}s',
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
            if (note.body != null && note.body!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  note.body!,
                  style: TextStyle(color: fg.withOpacity(0.8), fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        );
      case StickyNoteKind.image:
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: note.imagePath != null && File(note.imagePath!).existsSync()
              ? Image.file(File(note.imagePath!), height: 120, fit: BoxFit.cover)
              : Container(
                  height: 60,
                  color: fg.withOpacity(0.1),
                  alignment: Alignment.center,
                  child: Icon(Icons.broken_image, color: fg.withOpacity(0.5)),
                ),
        );
      case StickyNoteKind.handwriting:
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: note.handwritingPath != null && File(note.handwritingPath!).existsSync()
              ? Image.file(File(note.handwritingPath!), height: 100, fit: BoxFit.contain)
              : Container(
                  height: 60,
                  color: fg.withOpacity(0.1),
                  alignment: Alignment.center,
                  child: Icon(Icons.draw_outlined, color: fg.withOpacity(0.5)),
                ),
        );
    }
  }

  Widget _locationRow(BuildContext context, Color fg) {
    final pieces = <String>[];
    if (note.documentId != null) {
      pieces.add('Book');
      if (note.pageIndex != null) pieces.add('p.${note.pageIndex! + 1}');
    } else if (note.contextRoute != null) {
      pieces.add(_routeLabel(note.contextRoute!));
    } else {
      pieces.add('Anywhere');
    }
    pieces.add(_relative(note.updatedAt));
    return Text(
      pieces.join(' · '),
      style: TextStyle(
        color: fg.withOpacity(0.55),
        fontSize: 11,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  static String _routeLabel(String r) {
    return switch (r) {
      'library'      => 'Library',
      'scanner'      => 'Scanner',
      'settings'     => 'Settings',
      'home'         => 'Home',
      'editor'       => 'Editor',
      'handwriting'  => 'Sketchpad',
      _              => r,
    };
  }

  static String _relative(DateTime t) {
    final now = DateTime.now();
    final d = now.difference(t.toLocal());
    if (d.inMinutes < 1)  return 'just now';
    if (d.inHours   < 1)  return '${d.inMinutes}m ago';
    if (d.inDays    < 1)  return '${d.inHours}h ago';
    if (d.inDays    < 7)  return '${d.inDays}d ago';
    return '${t.toLocal().year}-${t.toLocal().month.toString().padLeft(2, "0")}-${t.toLocal().day.toString().padLeft(2, "0")}';
  }

  static Color _bgColor(String color) => switch (color) {
        'yellow' => const Color(0xFFFFF59D),
        'pink'   => const Color(0xFFF8BBD0),
        'green'  => const Color(0xFFC8E6C9),
        'blue'   => const Color(0xFFBBDEFB),
        'purple' => const Color(0xFFE1BEE7),
        'grey'   => const Color(0xFFE0E0E0),
        _        => const Color(0xFFFFF59D),
      };

  static Color _fgColor(String color) => switch (color) {
        'yellow' => const Color(0xFF5D4037),
        'pink'   => const Color(0xFF880E4F),
        'green'  => const Color(0xFF1B5E20),
        'blue'   => const Color(0xFF0D47A1),
        'purple' => const Color(0xFF4A148C),
        'grey'   => const Color(0xFF424242),
        _        => const Color(0xFF5D4037),
      };
}
