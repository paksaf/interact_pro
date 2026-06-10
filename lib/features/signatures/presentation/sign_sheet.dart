// SPDX-License-Identifier: AGPL-3.0
//
// Sign sheet — bottom sheet shown when the user taps the Sign button in
// the viewer toolbar. Phase 1 MVP: name + email + optional note → tap
// "Sign now" → records signature in DB → shows the audit code so the
// signer can quote it externally if needed.
//
// Phase 2 will add: stamp placement (drag a rect onto the page),
// signer-list mode (route to next person), and verification preview
// after signing. For now we capture the audit row only.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../lan/domain/entities.dart';
import '../../sharing/presentation/send_to_device_sheet.dart';
import '../data/signature_repository.dart';
import 'signature_provider.dart';

/// Opens [SignSheet] as a modal bottom sheet. Returns the [SignatureResult]
/// on success, or null if the user cancelled.
///
/// [pageIndex] is the page the visible stamp will be drawn on — defaults
/// to 0 (first page) when the caller can't easily get the current page.
/// Pass the actual viewer's currentPage when calling from the viewer
/// toolbar so the stamp lands on what the user is looking at.
Future<SignatureResult?> showSignSheet(
  BuildContext context, {
  required String documentId,
  required String pdfPath,
  int pageIndex = 0,
}) {
  return showModalBottomSheet<SignatureResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SignSheet(
      documentId: documentId,
      pdfPath: pdfPath,
      pageIndex: pageIndex,
    ),
  );
}

class SignSheet extends ConsumerStatefulWidget {
  const SignSheet({
    required this.documentId,
    required this.pdfPath,
    required this.pageIndex,
    super.key,
  });

  final String documentId;
  final String pdfPath;
  final int pageIndex;

  @override
  ConsumerState<SignSheet> createState() => _SignSheetState();
}

/// Four corner presets for the visible stamp's placement on the page.
/// Maps to fractional (x, y) anchors in [_kPresetFractions]. Default is
/// `bottomRight` — matches the embedder's default when no [StampPosition]
/// is passed, so this preset round-trips as a no-op override.
enum StampPlacementPreset {
  bottomRight,
  bottomLeft,
  topRight,
  topLeft,
}

/// Fractional anchors per preset. Width = 0.25, height = 0.08 of the
/// page (matches the embedder's 180×60 pt default on US-letter ≈ 0.29×0.076).
/// x/y are the TOP-LEFT corner of the stamp rect in page-relative coords.
/// We deliberately overshoot the embedder's 30pt edge margin slightly for
/// the side corners (x=0.05/0.70) to keep the stamp from kissing the edge
/// on very narrow page sizes.
const _kStampWFrac = 0.25;
const _kStampHFrac = 0.08;
const Map<StampPlacementPreset, ({double x, double y, IconData icon, String label})>
    _kPresetFractions = {
  StampPlacementPreset.bottomRight:
      (x: 0.70, y: 0.88, icon: Icons.south_east, label: 'Bottom right'),
  StampPlacementPreset.bottomLeft:
      (x: 0.05, y: 0.88, icon: Icons.south_west, label: 'Bottom left'),
  StampPlacementPreset.topRight:
      (x: 0.70, y: 0.04, icon: Icons.north_east, label: 'Top right'),
  StampPlacementPreset.topLeft:
      (x: 0.05, y: 0.04, icon: Icons.north_west, label: 'Top left'),
};

class _SignSheetState extends ConsumerState<SignSheet> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _busy = false;
  SignatureResult? _result;
  String? _error;

  /// Selected corner preset for the visible stamp. Defaults to bottom-right
  /// to match the embedder's original behaviour — users who don't touch the
  /// picker get exactly the Phase 2.5 placement.
  StampPlacementPreset _placement = StampPlacementPreset.bottomRight;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _signNow() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter your name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(signatureRepositoryProvider);
      final preset = _kPresetFractions[_placement]!;
      final result = await repo.signDocument(
        documentId: widget.documentId,
        pdfPath: widget.pdfPath,
        signerDisplayName: name,
        signerEmail: _emailCtrl.text.trim().isEmpty
            ? null
            : _emailCtrl.text.trim(),
        note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        pageIndex: widget.pageIndex,
        // Region pick: thread the user's chosen corner through as
        // fractional coords. signDocument forwards them into
        // StampPosition (page-relative 0..1) which the embedder
        // resolves to PDF points per the actual page size at draw time.
        // Width/height are constant fractions — corner choice only
        // moves the anchor.
        x: preset.x,
        y: preset.y,
        width: _kStampWFrac,
        height: _kStampHFrac,
        embedVisibleStamp: true,
      );
      // Refresh the document's signature list so the audit-trail UI updates.
      ref.invalidate(signaturesForDocumentProvider(widget.documentId));

      // Phase 2: write the sidecar JSON alongside the PDF. Best-effort
      // — if writing fails (e.g. PDF lives in a read-only location),
      // we surface the error in the success screen but don't block
      // the sign itself, which has already committed to the DB.
      try {
        final sidecar = ref.read(sigchainSidecarProvider);
        // Use the file's basename as the title for the sidecar manifest;
        // matches what the receiver will see when they import.
        final title = widget.pdfPath.split('/').last;
        await sidecar.write(
          pdfPath: widget.pdfPath,
          documentId: widget.documentId,
          documentTitle: title,
        );
      } catch (e) {
        // Non-fatal — log + continue. The DB row is the source of truth.
        // ignore: avoid_print
        print('[sign-sheet] sidecar write failed: $e');
      }

      if (mounted) {
        setState(() {
          _result = result;
          _busy = false;
        });
      }
    } catch (e, st) {
      // Keep error message human-readable; full stack traces go to logs.
      // (Tempting to use appLogger here but we deliberately don't import
      // it to keep this widget standalone — caller can wire one in.)
      // ignore: avoid_print
      print('[sign-sheet] sign failed: $e\n$st');
      if (mounted) {
        setState(() {
          _error = 'Signing failed: $e';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return SafeArea(
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.only(bottom: viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: _result == null
              ? _buildForm(cs)
              : _buildSuccess(cs, _result!),
        ),
      ),
    );
  }

  Widget _buildForm(ColorScheme cs) {
    return Column(
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
            Icon(Icons.gesture, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              'Sign this document',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Creates a cryptographically signed audit entry and draws a '
          'visible stamp on the page. Pick which corner the stamp lands '
          'in below.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _nameCtrl,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Your name',
            hintText: 'e.g. Muzafar Ahmed',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _emailCtrl,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Email (optional)',
            hintText: 'For audit-trail attribution',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _noteCtrl,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Note (optional)',
            hintText: 'e.g. "Approved for production"',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
        ),
        const SizedBox(height: 16),
        // Stamp placement picker — choose which corner the visible stamp
        // lands in on page ${widget.pageIndex + 1}. Default is bottom-right,
        // which matches every previous Pro release; the other three corners
        // are useful when the page already has content at the default slot
        // (letterhead in the bottom-right, page numbers, etc.). The page
        // index is fixed (taken from the viewer's current page) — only the
        // corner is configurable here.
        Text(
          'Stamp placement',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: cs.onSurface,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'Where the visible stamp will be drawn on page '
          '${widget.pageIndex + 1}.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        // SegmentedButton with 4 corner icons. Compact on phones; on
        // tablets the labels show alongside the icons because there's
        // room. SegmentedButton wraps onto multiple lines automatically
        // when constrained.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in _kPresetFractions.entries)
              ChoiceChip(
                avatar: Icon(
                  entry.value.icon,
                  size: 16,
                  color: _placement == entry.key
                      ? cs.onPrimary
                      : cs.onSurfaceVariant,
                ),
                label: Text(entry.value.label),
                selected: _placement == entry.key,
                onSelected: _busy
                    ? null
                    : (sel) {
                        if (!sel) return;
                        setState(() => _placement = entry.key);
                      },
                selectedColor: cs.primary,
                labelStyle: TextStyle(
                  color: _placement == entry.key
                      ? cs.onPrimary
                      : cs.onSurface,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, color: cs.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: cs.onErrorContainer),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _signNow,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.draw),
                label: Text(_busy ? 'Signing…' : 'Sign now'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccess(ColorScheme cs, SignatureResult r) {
    return Column(
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
        Icon(Icons.check_circle, color: cs.primary, size: 56),
        const SizedBox(height: 8),
        Text(
          'Signed',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        // Stamp status banner — green when the visible stamp was drawn
        // onto the PDF, amber when only the audit row landed (PDF was
        // read-only or unparseable). Either way the signature is valid;
        // this just clarifies what the recipient will see when they
        // open the file.
        if (r.stampEmbedded)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle_outline,
                    color: Colors.green.shade700, size: 18,),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Visible stamp drawn at '
                    '${_kPresetFractions[_placement]!.label.toLowerCase()} '
                    'of page ${widget.pageIndex + 1}.',
                    style: TextStyle(
                      color: Colors.green.shade900,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          )
        else if (r.stampError != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    color: Colors.orange.shade800, size: 18,),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Audit row saved, but visible stamp could not be '
                    'drawn (${r.stampError!.split("\n").first}). '
                    'Signature is still valid.',
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Audit code',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                r.shortCode,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 2,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                'Full code (UUID)',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                r.signatureRow.code,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              const SizedBox(height: 12),
              Text(
                'Signed at',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                DateTime.fromMillisecondsSinceEpoch(
                  r.signatureRow.timestampMs,
                ).toLocal().toString(),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Phase 3: hand off the signed document to the next signer over
        // LAN. Captures the root navigator BEFORE popping this sheet
        // because pop disposes this State's context. The opened sheet
        // (SendToDeviceSheet) pushes both the PDF + its .sigchain.json
        // sidecar to the chosen peer; receiver auto-imports the chain
        // and surfaces a "continue signing" snackbar.
        OutlinedButton.icon(
          onPressed: () {
            final root = Navigator.of(context, rootNavigator: true);
            final pdfPath = widget.pdfPath;
            Navigator.of(context).pop(r);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!root.mounted) return;
              SendToDeviceSheet.show(
                root.context,
                file: File(pdfPath),
                kind: ShareKind.pdf,
                suggestedName: p.basename(pdfPath),
                sendAsSignedDocument: true,
              );
            });
          },
          icon: const Icon(Icons.forward_to_inbox, size: 16),
          label: const Text('Send to next signer →'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(40),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: r.signatureRow.code),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Code copied')),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy code'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(r),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
