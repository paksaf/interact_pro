// SPDX-License-Identifier: AGPL-3.0
//
// TagPickerSheet — bottom sheet that lists all tags as toggleable chips
// for a single PDF. Initial selection reflects the tags already applied.
// On "Save", the repository syncs to the new selection (idempotent).
//
// Triggered from: library card long-press → "Tags…", and from the PDF
// detail screen's "Tags" row.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tag_chip.dart';
import 'tag_provider.dart';

/// Show the picker. Returns true when the user saved changes (caller
/// can refresh the library row), false if cancelled or unchanged.
Future<bool> showTagPickerSheet(
  BuildContext context, {
  required String documentId,
  required String documentTitle,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TagPickerSheet(
      documentId: documentId,
      documentTitle: documentTitle,
    ),
  );
  return result ?? false;
}

class TagPickerSheet extends ConsumerStatefulWidget {
  const TagPickerSheet({
    required this.documentId,
    required this.documentTitle,
    super.key,
  });

  final String documentId;
  final String documentTitle;

  @override
  ConsumerState<TagPickerSheet> createState() => _TagPickerSheetState();
}

class _TagPickerSheetState extends ConsumerState<TagPickerSheet> {
  Set<String>? _selectedIds; // null until first load completes
  bool _saving = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final allTagsAsync = ref.watch(allTagsProvider);
    final currentAsync = ref.watch(tagsForDocumentProvider(widget.documentId));

    // Seed selection from the document's current tags once.
    currentAsync.whenData((tags) {
      _selectedIds ??= tags.map((t) => t.id).toSet();
    });

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.35,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, scrollCtrl) => SingleChildScrollView(
            controller: scrollCtrl,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Icon(Icons.label_outline, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Tags',
                            style:
                                Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            widget.documentTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                allTagsAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => Text(
                    'Failed to load tags: $e',
                    style: TextStyle(color: cs.error),
                  ),
                  data: (tags) {
                    if (tags.isEmpty) {
                      return _EmptyHint();
                    }
                    final selected = _selectedIds ?? const <String>{};
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: tags.map((t) {
                        final isSelected = selected.contains(t.id);
                        return TagChip(
                          tag: t,
                          selected: isSelected,
                          onTap: _saving
                              ? null
                              : () => setState(() {
                                    final s = {...selected};
                                    if (isSelected) {
                                      s.remove(t.id);
                                    } else {
                                      s.add(t.id);
                                    }
                                    _selectedIds = s;
                                  }),
                        );
                      }).toList(),
                    );
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(color: cs.onErrorContainer),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Save'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final ids = _selectedIds?.toList() ?? const <String>[];
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(tagRepositoryProvider);
      await repo.setTagsForDocument(
        documentId: widget.documentId,
        tagIds: ids,
      );
      ref.invalidate(tagsForDocumentProvider(widget.documentId));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Save failed: $e';
          _saving = false;
        });
      }
    }
  }
}

class _EmptyHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.label_off_outlined, color: cs.onSurfaceVariant, size: 32),
          const SizedBox(height: 8),
          Text(
            'No tags yet',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Create your first tag in Settings → Tags. Try labels like '
            '"Contracts", "Reference", or "Q4 review" to group your PDFs.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
