// SPDX-License-Identifier: AGPL-3.0
//
// ZekaSolveSheet — Spike C.
//
// Modal bottom sheet that takes a question (pre-filled with selected
// PDF text or any user-typed prompt) and renders the Zeka response —
// numbered steps plus a `= answer` line at the bottom in mono.
//
// Use: `showModalBottomSheet(context: ..., builder: (_) => ZekaSolveSheet(
//   initialQuestion: highlightedText, imageBytes: optionalRegionPng))`
//
// The sheet auto-submits when [initialQuestion] is non-empty so a tap
// on "Solve with Zeka" from the viewer toolbar gets straight to the
// result instead of bouncing through a TextField first.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/zeka_solve_service.dart';

class ZekaSolveSheet extends ConsumerStatefulWidget {
  const ZekaSolveSheet({
    super.key,
    this.initialQuestion = '',
    this.imageBytes,
    this.imageMime = 'image/png',
  });

  /// Pre-fill — usually the selected text from the PDF, or the OCR
  /// transcription of a freehand selection region.
  final String initialQuestion;

  /// Optional cropped region of the page — when present we send a
  /// multimodal request. When null this is a text-only solve.
  final Uint8List? imageBytes;
  final String imageMime;

  @override
  ConsumerState<ZekaSolveSheet> createState() => _ZekaSolveSheetState();
}

class _ZekaSolveSheetState extends ConsumerState<ZekaSolveSheet> {
  late final TextEditingController _ctrl;
  ZekaSolveResult? _result;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuestion);
    if (widget.initialQuestion.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _solve());
    }
  }

  Future<void> _solve() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _result = null;
    });
    final svc = ref.read(zekaSolveServiceProvider);
    final result = widget.imageBytes != null
        ? await svc.solveImage(
            question: q,
            imageBytes: widget.imageBytes!,
            imageMime: widget.imageMime,
          )
        : await svc.solveText(q);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = result;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brown = const Color(0xFF4F3017);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calculate_outlined, color: brown),
                const SizedBox(width: 8),
                Text(
                  'Solve with Zeka',
                  style: TextStyle(
                      color: brown,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Ask a math, science, or unit-conversion question…',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _loading ? null : _solve,
                ),
              ),
              onSubmitted: (_) => _solve(),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_result != null && _result!.ok) _buildResult(brown),
            if (_result != null && !_result!.ok)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _result!.error ?? 'Zeka could not answer.',
                  style: TextStyle(color: Colors.red.shade900),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult(Color brown) {
    final r = _result!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in r.steps.indexed) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${i + 1}. $step',
              style: const TextStyle(fontSize: 14, height: 1.4),
            ),
          ),
        ],
        if (r.answer != null && r.answer!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: brown.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              r.answer!,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        if (r.provider != null) ...[
          const SizedBox(height: 8),
          Text(
            'via ${r.provider}',
            style: TextStyle(
              fontSize: 11,
              color: brown.withOpacity(0.6),
            ),
          ),
        ],
      ],
    );
  }
}
