import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/handwriting_repository_impl.dart';
import '../../domain/supported_languages.dart';
import '../providers/handwriting_controller.dart';

/// Modal sheet listing supported handwriting languages. Picking one
/// switches the active language; tapping the trash icon next to a
/// downloaded model deletes it (useful for users who experimented with
/// every language and want their storage back).
///
/// Returns the chosen tag via Navigator.pop, but the controller is
/// updated synchronously so callers don't have to do anything with the
/// return value.
class LanguagePickerSheet extends ConsumerStatefulWidget {
  const LanguagePickerSheet({super.key});

  @override
  ConsumerState<LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends ConsumerState<LanguagePickerSheet> {
  /// Per-row download state. We don't poll ML Kit for every language on
  /// open — that would add 18 native round-trips and cause a noticeable
  /// hitch. Instead each row checks itself lazily on first build.
  final Map<String, _RowState> _rows = {};

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(handwritingControllerProvider);
    final controller = ref.read(handwritingControllerProvider.notifier);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) {
        return SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Text(
                'Handwriting language',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Models download once per language (10–20MB), then '
                'recognition runs on-device with no network.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 16),
              for (final lang in HandwritingLanguage.presets)
                _LanguageRow(
                  language: lang,
                  isSelected: state.languageTag == lang.tag,
                  onSelect: () async {
                    await controller.setLanguage(lang.tag);
                    if (mounted) Navigator.of(context).pop();
                  },
                  rowState: _rows.putIfAbsent(lang.tag, () => _RowState()),
                  onDelete: () async {
                    await controller.deleteModel(lang.tag);
                    if (!mounted) return;
                    setState(() {
                      _rows[lang.tag] = _RowState(downloaded: false);
                    });
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _RowState {
  _RowState({this.downloaded});
  bool? downloaded;
}

class _LanguageRow extends ConsumerStatefulWidget {
  const _LanguageRow({
    required this.language,
    required this.isSelected,
    required this.onSelect,
    required this.rowState,
    required this.onDelete,
  });

  final HandwritingLanguage language;
  final bool isSelected;
  final VoidCallback onSelect;
  final _RowState rowState;
  final VoidCallback onDelete;

  @override
  ConsumerState<_LanguageRow> createState() => _LanguageRowState();
}

class _LanguageRowState extends ConsumerState<_LanguageRow> {
  @override
  void initState() {
    super.initState();
    if (widget.rowState.downloaded == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _probe());
    }
  }

  Future<void> _probe() async {
    // Probe via a sibling provider rather than going through the
    // [HandwritingController] — switching to the language to check
    // would side-effect the active language state for every row.
    final repo = ref.read(handwritingRepoProbeProvider);
    final r = await repo.isModelDownloaded(widget.language.tag);
    if (!mounted) return;
    r.fold(
      (downloaded) {
        setState(() => widget.rowState.downloaded = downloaded);
      },
      (_) {
        // If the SDK errors on this language tag (rare — usually means
        // it's not actually a supported model id), treat as not downloaded.
        setState(() => widget.rowState.downloaded = false);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final downloaded = widget.rowState.downloaded;
    return Material(
      color: widget.isSelected ? cs.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(
                widget.isSelected ? Icons.check_circle : Icons.circle_outlined,
                color: widget.isSelected ? cs.primary : cs.outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.language.label,
                      style: TextStyle(
                        fontWeight: widget.isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${widget.language.tag} · ${widget.language.script} '
                      '${downloaded == null ? '· checking…' : downloaded ? '· downloaded' : ''}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.outline,
                      ),
                    ),
                  ],
                ),
              ),
              if (downloaded == true)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete this model',
                  onPressed: widget.onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tiny indirection so language rows can probe model state without
/// going through the [HandwritingController] (which would mutate the
/// active-language state every time it ran).
final handwritingRepoProbeProvider = Provider((ref) {
  return ref.watch(handwritingRepositoryProvider);
});
