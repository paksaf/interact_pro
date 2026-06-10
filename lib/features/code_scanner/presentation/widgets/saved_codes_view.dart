import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/storage/app_database.dart' as db;
import '../../data/saved_codes_repository.dart';
import '../../domain/scan_result.dart';

/// History view rendering both scanned and generated codes from the
/// [SavedCodes] drift table. Tap a row → re-uses the code (opens URL,
/// dials, etc. mirroring the live result sheet); long-press deletes.
///
/// Filtering: search box matches raw value or label, segmented filter
/// across All / Scanned / Generated.
class SavedCodesView extends ConsumerStatefulWidget {
  const SavedCodesView({this.onUseAsStamp, super.key});

  /// When non-null, surfaces a "Use as stamp" action on generated rows
  /// that have a saved [imagePath]. Hosts (the Scan tab) wire this to
  /// the StampPickerSheet image-stamp flow.
  final void Function(db.SavedCode code)? onUseAsStamp;

  @override
  ConsumerState<SavedCodesView> createState() => _SavedCodesViewState();
}

class _SavedCodesViewState extends ConsumerState<SavedCodesView> {
  String _query = '';
  String? _origin; // null = all

  List<db.SavedCode> _filter(List<db.SavedCode> all) {
    final q = _query.trim().toLowerCase();
    return all.where((c) {
      if (_origin != null && c.origin != _origin) return false;
      if (q.isEmpty) return true;
      if (c.rawValue.toLowerCase().contains(q)) return true;
      if ((c.label ?? '').toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final asyncCodes = ref.watch(savedCodesStreamProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search by content or label',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<String?>(
            segments: const [
              ButtonSegment(value: null, label: Text('All')),
              ButtonSegment(
                value: SavedCodesRepository.originScanned,
                label: Text('Scanned'),
              ),
              ButtonSegment(
                value: SavedCodesRepository.originGenerated,
                label: Text('Generated'),
              ),
            ],
            selected: {_origin},
            onSelectionChanged: (s) => setState(() => _origin = s.first),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: asyncCodes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load: $e')),
            data: (all) {
              final filtered = _filter(all);
              if (filtered.isEmpty) return _empty(context, all.isEmpty);
              return ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _Row(
                  code: filtered[i],
                  onTap: () => _activate(filtered[i]),
                  onCopy: () async {
                    await Clipboard.setData(
                      ClipboardData(text: filtered[i].rawValue),
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                  onDelete: () => _delete(filtered[i]),
                  onUseAsStamp: widget.onUseAsStamp == null
                      ? null
                      : () => widget.onUseAsStamp!(filtered[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context, bool absoluteEmpty) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              absoluteEmpty ? Icons.qr_code_2 : Icons.search_off,
              size: 80,
              color: cs.outline,
            ),
            const SizedBox(height: 16),
            Text(
              absoluteEmpty ? 'No saved codes yet' : 'No matches',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              absoluteEmpty
                  ? 'Scanned and generated codes will appear here.'
                  : 'Nothing matches "$_query".',
              style: TextStyle(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _activate(db.SavedCode code) async {
    final kind = classifyCode(code.rawValue);
    switch (kind) {
      case ScannedCodeKind.url:
        final uri = Uri.tryParse(code.rawValue);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      case ScannedCodeKind.email:
        final addr = code.rawValue.startsWith('mailto:')
            ? code.rawValue
            : 'mailto:${code.rawValue}';
        final uri = Uri.tryParse(addr);
        if (uri != null && await canLaunchUrl(uri)) await launchUrl(uri);
      case ScannedCodeKind.phone:
        final tel = code.rawValue.startsWith('tel:') ||
                code.rawValue.startsWith('sms:')
            ? code.rawValue
            : 'tel:${code.rawValue}';
        final uri = Uri.tryParse(tel);
        if (uri != null && await canLaunchUrl(uri)) await launchUrl(uri);
      case ScannedCodeKind.wifi:
      case ScannedCodeKind.geo:
      case ScannedCodeKind.vcard:
      case ScannedCodeKind.text:
        await Clipboard.setData(ClipboardData(text: code.rawValue));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Copied to clipboard')),
        );
    }
  }

  Future<void> _delete(db.SavedCode code) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this code?'),
        content: Text(
          code.label?.isNotEmpty == true
              ? '"${code.label}" will be removed from your history.'
              : 'This entry will be removed from your history.',
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
    if (ok != true) return;
    await ref.read(savedCodesRepositoryProvider).remove(code.id);
    // Best-effort image cleanup; missing files are fine.
    final p = code.imagePath;
    if (p != null) {
      try {
        final f = File(p);
        if (f.existsSync()) await f.delete();
      } catch (_) {/* ignore */}
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.code,
    required this.onTap,
    required this.onCopy,
    required this.onDelete,
    required this.onUseAsStamp,
  });

  final db.SavedCode code;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback? onUseAsStamp;

  @override
  Widget build(BuildContext context) {
    final isGenerated =
        code.origin == SavedCodesRepository.originGenerated;
    final dateFmt = DateFormat.yMMMd().add_jm();
    final cs = Theme.of(context).colorScheme;
    final canStamp = isGenerated &&
        (code.imagePath ?? '').isNotEmpty &&
        File(code.imagePath!).existsSync() &&
        onUseAsStamp != null;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isGenerated
            ? cs.tertiaryContainer
            : cs.primaryContainer,
        foregroundColor: isGenerated
            ? cs.onTertiaryContainer
            : cs.onPrimaryContainer,
        child: Icon(isGenerated ? Icons.qr_code_2 : Icons.qr_code_scanner),
      ),
      title: Text(
        code.label?.isNotEmpty == true ? code.label! : code.rawValue,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (code.label?.isNotEmpty == true)
            Text(
              code.rawValue,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          Text(
            '${code.format} · ${dateFmt.format(code.createdAt)}',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          switch (v) {
            case 'copy':
              onCopy();
            case 'stamp':
              onUseAsStamp?.call();
            case 'delete':
              onDelete();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'copy',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.copy),
              title: Text('Copy'),
            ),
          ),
          if (canStamp)
            const PopupMenuItem(
              value: 'stamp',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.approval_outlined),
                title: Text('Use as stamp'),
              ),
            ),
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.delete_outline),
              title: Text('Delete'),
            ),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
