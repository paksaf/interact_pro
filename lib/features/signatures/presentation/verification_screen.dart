// SPDX-License-Identifier: AGPL-3.0
//
// Verification screen — lists all signatures on a PDF with their
// verification status. Each row runs SignatureRepository.verifySignature
// and renders one of four states from the sealed VerificationResult:
//
//   ✓ Valid                — Ed25519 verify passes AND current PDF
//                            hash matches the hash at sign time
//   ✗ Bad signature        — Ed25519 verify fails (key mismatch or
//                            corrupted signature bytes)
//   ⚠ Document altered     — PDF hash changed since signing (anyone
//                            edited the PDF after this signature)
//   ? Unknown signer       — Signer's public key isn't in our local
//                            identity table; signature can't be verified
//                            without their pubkey. Import the sidecar
//                            JSON to add their identity.
//
// Reachable from:
//   - viewer toolbar More menu → "View signatures"
//   - Settings → "Find signed PDF" → tap a result
//   - SignSheet success screen → "View chain"

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/app_database.dart';
import '../data/signature_repository.dart';
import 'signature_provider.dart';

class VerificationScreen extends ConsumerWidget {
  const VerificationScreen({
    required this.documentId,
    required this.pdfPath,
    required this.documentTitle,
    super.key,
  });

  final String documentId;
  final String pdfPath;
  final String documentTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signaturesAsync =
        ref.watch(signaturesForDocumentProvider(documentId));
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Signatures'),
            Text(
              documentTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
      body: signaturesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              'Failed to load signatures: $e',
              style: TextStyle(color: cs.error),
            ),
          ),
        ),
        data: (sigs) {
          if (sigs.isEmpty) return _EmptyState();
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: sigs.length,
            itemBuilder: (_, i) => _SignatureCard(
              signature: sigs[i],
              pdfPath: pdfPath,
              index: i + 1,
              total: sigs.length,
            ),
          );
        },
      ),
    );
  }
}

class _SignatureCard extends ConsumerStatefulWidget {
  const _SignatureCard({
    required this.signature,
    required this.pdfPath,
    required this.index,
    required this.total,
  });

  final Signature signature;
  final String pdfPath;
  final int index;
  final int total;

  @override
  ConsumerState<_SignatureCard> createState() => _SignatureCardState();
}

class _SignatureCardState extends ConsumerState<_SignatureCard> {
  VerificationResult? _result;
  SigningIdentity? _identity;
  bool _verifying = false;
  String? _error;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _runVerify();
  }

  Future<void> _runVerify() async {
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final repo = ref.read(signatureRepositoryProvider);
      final keys = ref.read(signingKeysServiceProvider);
      final result = await repo.verifySignature(
        signature: widget.signature,
        currentPdfPath: widget.pdfPath,
      );
      final identity = await keys.lookupIdentity(widget.signature.signerId);
      if (mounted) {
        setState(() {
          _result = result;
          _identity = identity;
          _verifying = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _verifying = false;
        });
      }
    }
  }

  Color _statusColor(VerificationResult? r, ColorScheme cs) {
    if (r == null) return cs.onSurfaceVariant;
    return switch (r.kind) {
      'valid' => Colors.green.shade700,
      'badSignature' => cs.error,
      'documentAltered' => Colors.orange.shade700,
      'unknownSigner' => Colors.blueGrey.shade700,
      _ => cs.onSurfaceVariant,
    };
  }

  IconData _statusIcon(VerificationResult? r) {
    if (r == null) return Icons.hourglass_top;
    return switch (r.kind) {
      'valid' => Icons.check_circle,
      'badSignature' => Icons.cancel,
      'documentAltered' => Icons.warning_amber,
      'unknownSigner' => Icons.help_outline,
      _ => Icons.help_outline,
    };
  }

  String _statusLabel(VerificationResult? r) {
    if (r == null) return 'Verifying…';
    return switch (r.kind) {
      'valid' => 'Valid signature',
      'badSignature' => 'Bad signature',
      'documentAltered' => 'Document altered after signing',
      'unknownSigner' => 'Unknown signer — import sidecar to verify',
      _ => 'Unknown status',
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.signature;
    final statusColor = _statusColor(_result, cs);
    final shortCode = s.code
        .replaceAll('-', '')
        .substring(0, 8)
        .toUpperCase();
    final signerName = _identity?.name ?? '(unknown signer)';
    final timestamp = DateTime.fromMillisecondsSinceEpoch(s.timestampMs)
        .toLocal()
        .toString();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: _verifying
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: statusColor,
                          ),
                        )
                      : Icon(_statusIcon(_result),
                          color: statusColor, size: 22,),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        signerName,
                        style: Theme.of(context).textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _statusLabel(_result),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(
                              color: statusColor,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(
                    'Sig ${widget.index}/${widget.total}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Always-visible quick facts row
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _Fact(label: 'Code', value: shortCode, mono: true),
                _Fact(label: 'Signed', value: _formatRelative(s.timestampMs)),
              ],
            ),
            const SizedBox(height: 8),
            // Expand-for-details
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Text(
                    _expanded ? 'Hide details' : 'Show details',
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: cs.primary,
                    size: 18,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 4),
              _DetailRow(label: 'Full code', value: s.code, mono: true),
              _DetailRow(label: 'Timestamp', value: timestamp),
              _DetailRow(
                label: 'PDF hash at sign',
                value: s.pdfHashHex,
                mono: true,
                wrap: true,
              ),
              if (_identity != null && _identity!.email != null)
                _DetailRow(label: 'Signer email', value: _identity!.email!),
              if (s.note != null && s.note!.trim().isNotEmpty)
                _DetailRow(label: 'Note', value: s.note!),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy full code'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: s.code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Re-verify'),
                    onPressed: _verifying ? null : _runVerify,
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: cs.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatRelative(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.mono = false});
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
    this.wrap = false,
  });

  final String label;
  final String value;
  final bool mono;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: 12,
              fontFamily: mono ? 'monospace' : null,
            ),
            maxLines: wrap ? 3 : 1,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.draw_outlined,
                size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4),),
            const SizedBox(height: 12),
            Text(
              'No signatures yet',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the Sign icon in the viewer toolbar to add the first '
              'signature to this document.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

