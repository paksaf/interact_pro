import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/hotspot_repository.dart';
import '../../domain/hotspot.dart';

/// Returned by [HotspotCreateSheet]. The viewer takes this and persists it
/// via [DriftHotspotRepository.add] — keeping the sheet itself stateless on
/// network/db. Kept tiny so callers don't have to import drift internals.
class HotspotDraft {
  const HotspotDraft({required this.kind, required this.content});
  final HotspotKind kind;
  final String content;
}

/// Modal sheet for creating a new hotspot. Lets the user pick a type
/// (Note / Link) and enter content. Image / audio types are gated behind
/// the Pro upsell — exposed as disabled tiles for now.
class HotspotCreateSheet extends StatefulWidget {
  const HotspotCreateSheet({super.key});

  @override
  State<HotspotCreateSheet> createState() => _HotspotCreateSheetState();
}

class _HotspotCreateSheetState extends State<HotspotCreateSheet> {
  HotspotKind _kind = HotspotKind.note;
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.add_circle_outline),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'New hotspot',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<HotspotKind>(
                segments: const [
                  ButtonSegment(
                    value: HotspotKind.note,
                    icon: Icon(Icons.sticky_note_2_outlined),
                    label: Text('Note'),
                  ),
                  ButtonSegment(
                    value: HotspotKind.link,
                    icon: Icon(Icons.link),
                    label: Text('Link'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ctrl,
                autofocus: true,
                minLines: _kind == HotspotKind.note ? 3 : 1,
                maxLines: _kind == HotspotKind.note ? 6 : 1,
                keyboardType: _kind == HotspotKind.link
                    ? TextInputType.url
                    : TextInputType.multiline,
                textCapitalization: _kind == HotspotKind.note
                    ? TextCapitalization.sentences
                    : TextCapitalization.none,
                inputFormatters: _kind == HotspotKind.link
                    ? [FilteringTextInputFormatter.deny(RegExp(r'\s'))]
                    : null,
                decoration: InputDecoration(
                  labelText: _kind == HotspotKind.note ? 'Note text' : 'URL',
                  hintText: _kind == HotspotKind.note
                      ? 'A short note pinned to this page…'
                      : 'https://…',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Add'),
                    onPressed: () {
                      final content = _ctrl.text.trim();
                      if (content.isEmpty) return;
                      Navigator.of(context).pop(
                        HotspotDraft(kind: _kind, content: content),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Modal sheet that lists every hotspot in a document, grouped by page.
/// Tap a hotspot to reveal its content (or open the URL); long-press to
/// delete with confirmation.
class HotspotListSheet extends ConsumerWidget {
  const HotspotListSheet({
    required this.documentUuid,
    required this.onJumpToPage,
    super.key,
  });

  final String documentUuid;
  final void Function(int pageNumber) onJumpToPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncHotspots = ref.watch(hotspotsForDocumentProvider(documentUuid));
    return SafeArea(
      child: DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) {
          return asyncHotspots.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load hotspots: $e'),
            ),
            data: (hotspots) {
              if (hotspots.isEmpty) {
                return _emptyState(context);
              }
              return ListView.separated(
                controller: scrollController,
                itemCount: hotspots.length + 1,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Text(
                        'Hotspots · ${hotspots.length}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  final h = hotspots[index - 1];
                  return _HotspotTile(
                    hotspot: h,
                    onTap: () => _activate(context, h),
                    onJump: () {
                      Navigator.of(context).pop();
                      onJumpToPage(h.pageNumber);
                    },
                    onDelete: () async {
                      final confirm = await _confirmDelete(context, h);
                      if (confirm != true) return;
                      await ref
                          .read(hotspotRepositoryProvider)
                          .remove(h.id);
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_searching, size: 80, color: cs.outline),
            const SizedBox(height: 16),
            Text(
              'No hotspots yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Long-press a region of any page to pin a note or link.',
              style: TextStyle(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _activate(BuildContext context, Hotspot h) async {
    switch (h.payload) {
      case NotePayload(:final text):
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('Note · page ${h.pageNumber}'),
            content: SelectableText(text),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      case LinkPayload(:final url):
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } else if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open $url')),
          );
        }
      case ImagePayload():
      case AudioPayload():
        // Image / audio not yet rendered in-app; surface the path so power
        // users can find it on disk via Files or adb.
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Media hotspots — coming in Pro.')),
        );
    }
  }

  Future<bool?> _confirmDelete(BuildContext context, Hotspot h) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete hotspot?'),
        content: Text(
          'Removes this ${_describe(h)} from page ${h.pageNumber}. '
          'The PDF itself is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _describe(Hotspot h) => switch (h.kind) {
        HotspotKind.note => 'note',
        HotspotKind.link => 'link',
        HotspotKind.image => 'image hotspot',
        HotspotKind.audio => 'audio hotspot',
      };
}

class _HotspotTile extends StatelessWidget {
  const _HotspotTile({
    required this.hotspot,
    required this.onTap,
    required this.onJump,
    required this.onDelete,
  });
  final Hotspot hotspot;
  final VoidCallback onTap;
  final VoidCallback onJump;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final preview = switch (hotspot.payload) {
      NotePayload(:final text) => text,
      LinkPayload(:final url) => url,
      ImagePayload(:final imagePath) => imagePath,
      AudioPayload(:final audioPath) => audioPath,
    };
    final icon = switch (hotspot.kind) {
      HotspotKind.note => Icons.sticky_note_2_outlined,
      HotspotKind.link => Icons.link,
      HotspotKind.image => Icons.image_outlined,
      HotspotKind.audio => Icons.audiotrack,
    };
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
        child: Icon(icon),
      ),
      title: Text(
        preview,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('Page ${hotspot.pageNumber}'),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'jump':
              onJump();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'jump',
            child: ListTile(
              leading: Icon(Icons.open_in_browser),
              title: Text('Jump to page'),
              dense: true,
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Delete'),
              dense: true,
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
