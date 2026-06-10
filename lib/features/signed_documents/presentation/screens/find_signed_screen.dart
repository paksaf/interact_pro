import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../../../core/routing/app_routes.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/logger.dart';

/// Browse + search the signed-PDF archive built up by the viewer's
/// "Save signed copy" dialog.
///
/// **Storage model:** every `Save Signed Copy` writes two files to the
/// app's `signed/` folder — the PDF itself and a `.json` sidecar with
/// `{name, code, savedAt, sourceFile, pdfPath}`. This screen scans those
/// JSON files, lets the user search by name or code, and opens the
/// matching PDF in the viewer.
class FindSignedScreen extends ConsumerStatefulWidget {
  const FindSignedScreen({super.key});

  @override
  ConsumerState<FindSignedScreen> createState() => _FindSignedScreenState();
}

class _FindSignedScreenState extends ConsumerState<FindSignedScreen> {
  final _searchController = TextEditingController();
  Future<List<_SignedRecord>>? _records;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() => _records = _loadRecords());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<_SignedRecord>> _loadRecords() async {
    final paths = await ref.read(appPathsProvider.future);
    final signedDir = Directory(p.join(paths.pdfDir.parent.path, 'signed'));
    if (!signedDir.existsSync()) return [];

    final jsonFiles = signedDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.json'))
        .toList();

    final records = <_SignedRecord>[];
    for (final f in jsonFiles) {
      try {
        final raw = await f.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        records.add(_SignedRecord(
          name: (json['name'] as String? ?? '').trim(),
          code: (json['code'] as String?)?.trim(),
          savedAt: DateTime.tryParse(json['savedAt'] as String? ?? '') ??
              f.statSync().modified,
          pdfPath: json['pdfPath'] as String? ?? '',
          sourceFile: json['sourceFile'] as String? ?? '',
        ),);
      } catch (e) {
        appLogger.w('signed sidecar parse failed at ${f.path}: $e');
      }
    }
    // Newest first.
    records.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return records;
  }

  List<_SignedRecord> _filter(List<_SignedRecord> all) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((r) {
      if (r.name.toLowerCase().contains(q)) return true;
      if (r.code != null && r.code!.toLowerCase().contains(q)) return true;
      return false;
    }).toList();
  }

  Future<void> _delete(_SignedRecord r) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete signed copy?'),
        content: Text('"${r.name}" will be permanently removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final pdf = File(r.pdfPath);
      if (pdf.existsSync()) await pdf.delete();
      // The sidecar lives next to the PDF with the same basename + .json.
      final base = p.withoutExtension(r.pdfPath);
      final json = File('$base.json');
      if (json.existsSync()) await json.delete();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not delete: $e')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _records = _loadRecords());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Find signed PDF')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Search by name or code',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<_SignedRecord>>(
              future: _records,
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = snap.data!;
                if (all.isEmpty) {
                  return const _EmptyState(
                    icon: Icons.draw_outlined,
                    title: 'No signed PDFs yet',
                    body: 'Sign a PDF and save it with a name and code to '
                        'see it here.',
                  );
                }
                final filtered = _filter(all);
                if (filtered.isEmpty) {
                  return _EmptyState(
                    icon: Icons.search_off,
                    title: 'No matches',
                    body: 'Nothing matches "$_query".',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    setState(() => _records = _loadRecords());
                    await _records;
                  },
                  child: ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _RecordTile(
                      record: filtered[i],
                      onTap: () => context.pushNamed(
                        AppRoutes.viewer,
                        extra: filtered[i].pdfPath,
                      ),
                      onDelete: () => _delete(filtered[i]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SignedRecord {
  const _SignedRecord({
    required this.name,
    required this.code,
    required this.savedAt,
    required this.pdfPath,
    required this.sourceFile,
  });
  final String name;
  final String? code;
  final DateTime savedAt;
  final String pdfPath;
  final String sourceFile;

  bool get fileExists => File(pdfPath).existsSync();
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.record,
    required this.onTap,
    required this.onDelete,
  });
  final _SignedRecord record;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat.yMMMd().add_jm();
    final missing = !record.fileExists;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: missing
            ? Theme.of(context).colorScheme.errorContainer
            : Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: missing
            ? Theme.of(context).colorScheme.onErrorContainer
            : Theme.of(context).colorScheme.onPrimaryContainer,
        child: Icon(missing ? Icons.error_outline : Icons.draw),
      ),
      title: Text(
        record.name.isEmpty ? '(unnamed)' : record.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (record.code != null && record.code!.isNotEmpty)
            Text(
              'Code · ${record.code}',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          Text(
            'Saved ${dateFmt.format(record.savedAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (record.sourceFile.isNotEmpty)
            Text(
              'From ${record.sourceFile}',
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (missing)
            const Text(
              'File missing — was it deleted outside the app?',
              style: TextStyle(color: Colors.red, fontSize: 11),
            ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') onDelete();
        },
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Delete'),
              dense: true,
            ),
          ),
        ],
      ),
      onTap: missing ? null : onTap,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 96, color: cs.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
