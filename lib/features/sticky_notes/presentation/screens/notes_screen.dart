// SPDX-License-Identifier: AGPL-3.0
//
// Notes screen — grid of sticky notes with search + kind filter + trash.
// Floating action button opens the four-button capture sheet.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sticky_note_repository.dart';
import '../widgets/sticky_note_card.dart';
import 'note_capture_sheet.dart';
import 'note_detail_screen.dart';

class NotesScreen extends ConsumerStatefulWidget {
  const NotesScreen({super.key});
  @override
  ConsumerState<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends ConsumerState<NotesScreen> {
  Set<StickyNoteKind> _kinds = const {};
  String _query = '';
  bool _showArchived = false;
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = StickyNoteFilter(
      kinds: _kinds,
      query: _query.isEmpty ? null : _query,
      showArchived: _showArchived,
    );
    final notesAsync = ref.watch(stickyNotesProvider(filter));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sticky Notes'),
        actions: [
          IconButton(
            icon: Icon(_showArchived ? Icons.delete_forever : Icons.delete_outline),
            tooltip: _showArchived ? 'Hide Trash' : 'Show Trash',
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search notes…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _kindChip('All', _kinds.isEmpty, () => setState(() => _kinds = const {})),
                ...StickyNoteKind.values.map((k) => _kindChip(
                      _kindLabel(k),
                      _kinds.contains(k),
                      () => setState(() {
                        final next = Set<StickyNoteKind>.from(_kinds);
                        if (!next.add(k)) next.remove(k);
                        _kinds = next;
                      }),
                    ),),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: notesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Failed to load notes: $e')),
              data: (notes) {
                if (notes.isEmpty) return _emptyState();
                return GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisExtent: 200,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: notes.length,
                  itemBuilder: (ctx, i) {
                    final n = notes[i];
                    return StickyNoteCard(
                      note: n,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => NoteDetailScreen(noteId: n.id)),
                      ),
                      onLongPress: () => _onLongPress(n.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: _showArchived
          ? null
          : FloatingActionButton.extended(
              onPressed: () => showNoteCaptureSheet(context),
              icon: const Icon(Icons.add),
              label: const Text('Capture'),
            ),
    );
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sticky_note_2_outlined, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                _showArchived ? 'Trash is empty.' : 'No notes yet.',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              if (!_showArchived)
                const Text(
                  'Tap Capture to add your first note — text, voice, image, or handwriting.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
            ],
          ),
        ),
      );

  Widget _kindChip(String label, bool selected, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );

  static String _kindLabel(StickyNoteKind k) => switch (k) {
        StickyNoteKind.text        => 'Text',
        StickyNoteKind.voice       => 'Voice',
        StickyNoteKind.image       => 'Image',
        StickyNoteKind.handwriting => 'Sketch',
      };

  Future<void> _onLongPress(String noteId) async {
    final repo = ref.read(stickyNoteRepositoryProvider);
    final note = await repo.findById(noteId);
    if (note == null || !mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(note.pinned ? 'Unpin' : 'Pin'),
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            if (note.archivedAt == null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Move to Trash'),
                onTap: () => Navigator.pop(ctx, 'archive'),
              )
            else ...[
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('Restore'),
                onTap: () => Navigator.pop(ctx, 'unarchive'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever),
                title: const Text('Delete forever'),
                onTap: () => Navigator.pop(ctx, 'deleteForever'),
              ),
            ],
          ],
        ),
      ),
    );
    switch (action) {
      case 'pin':           await repo.togglePinned(note.id, !note.pinned);
      case 'archive':       await repo.archive(note.id);
      case 'unarchive':     await repo.unarchive(note.id);
      case 'deleteForever': await repo.deleteForever(note.id);
    }
  }
}
