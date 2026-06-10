import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../viewer/domain/entities/pdf_document.dart';

/// Recent-files list shown on Home. Each tile opens the document in the
/// viewer via [onTap]. Long-press shows a contextual sheet (rename, delete,
/// share, save to Drive) — keep that wired in callers.
class RecentDocuments extends StatelessWidget {
  const RecentDocuments({
    required this.documents,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final List<PdfDocument> documents;
  final ValueChanged<PdfDocument> onTap;
  final ValueChanged<PdfDocument>? onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: documents.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
      itemBuilder: (context, i) => _DocumentTile(
        doc: documents[i],
        onTap: () => onTap(documents[i]),
        onLongPress: onLongPress == null ? null : () => onLongPress!(documents[i]),
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.doc,
    required this.onTap,
    this.onLongPress,
  });

  final PdfDocument doc;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dateFmt = DateFormat.yMMMd().add_jm();

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        child: const Icon(Icons.picture_as_pdf),
      ),
      title: Text(
        doc.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${doc.pageCount} pages · ${_formatBytes(doc.sizeBytes)} · '
        'Updated ${dateFmt.format(doc.updatedAt)}',
        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (doc.isDigitallySigned)
            const Tooltip(
              message: 'Digitally signed',
              child: Icon(Icons.verified, size: 18, color: Colors.green),
            ),
          if (doc.driveFileId != null)
            Tooltip(
              message: 'Synced to Drive',
              child: Icon(Icons.cloud_done, size: 18, color: cs.primary),
            ),
          if (doc.isOcrApplied)
            Tooltip(
              message: 'OCR applied',
              child: Icon(Icons.text_snippet, size: 18, color: cs.secondary),
            ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
