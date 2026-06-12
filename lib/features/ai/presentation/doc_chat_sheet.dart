// SPDX-License-Identifier: AGPL-3.0
//
// DocChatSheet — the chat-with-document UI (market-fit Gate B). Opens from the
// viewer's "Ask AI" action. Preset chips (Summarize / Extract / Translate) +
// free-form Ask, grounded in the open PDF's text. Scanned PDFs are caught with
// a "run OCR first" hint; non-Pro users get an upgrade nudge.

import 'package:flutter/material.dart';

import '../data/doc_ai_service.dart';

class DocChatSheet extends StatefulWidget {
  const DocChatSheet({
    required this.filePath,
    required this.currentPage,
    this.onUpgrade,
    super.key,
  });

  final String filePath;
  final int currentPage; // 1-based
  final VoidCallback? onUpgrade;

  static Future<void> show(BuildContext context,
      {required String filePath, required int currentPage, VoidCallback? onUpgrade}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: DocChatSheet(
            filePath: filePath, currentPage: currentPage, onUpgrade: onUpgrade),
      ),
    );
  }

  @override
  State<DocChatSheet> createState() => _DocChatSheetState();
}

class _DocChatSheetState extends State<DocChatSheet> {
  final _svc = DocAiService();
  final _ctrl = TextEditingController();
  final _history = <Map<String, String>>[];
  bool _busy = false;
  String? _error;
  String? _answer;
  bool _truncated = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run(DocAiMode mode, {String? question, String? lang}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Summarize/translate whole doc from page 1; Ask/Extract use the page
      // window around what the user is reading (keeps long PDFs bounded).
      final around = (mode == DocAiMode.summarize || mode == DocAiMode.translate)
          ? null
          : widget.currentPage;
      final text = await _svc.extractText(widget.filePath, aroundPage: around);
      if (text.isEmpty) {
        setState(() {
          _busy = false;
          _error = 'No selectable text — this PDF looks scanned. Run OCR first, then ask again.';
        });
        return;
      }
      final r = await _svc.chat(
        docText: text,
        mode: mode,
        question: question,
        targetLang: lang,
        history: _history,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (r.upgrade) {
          _error = r.error;
        } else if (!r.ok) {
          _error = r.error;
        } else {
          _answer = r.answer;
          _truncated = r.truncated;
          if (question != null) _history.add({'role': 'user', 'content': question});
          if (r.answer != null) _history.add({'role': 'assistant', 'content': r.answer!});
        }
      });
      if (r.upgrade && widget.onUpgrade != null) {
        // let the host show the paywall after the sheet settles
      }
    } catch (e) {
      if (mounted) setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shrinkWrap: true,
        children: [
          Row(children: const [
            Icon(Icons.auto_awesome, size: 18),
            SizedBox(width: 8),
            Text('Ask this document', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ActionChip(
                avatar: const Icon(Icons.summarize, size: 16),
                label: const Text('Summarize'),
                onPressed: _busy ? null : () => _run(DocAiMode.summarize)),
            ActionChip(
                avatar: const Icon(Icons.list_alt, size: 16),
                label: const Text('Key facts'),
                onPressed: _busy ? null : () => _run(DocAiMode.extract)),
            ActionChip(
                avatar: const Icon(Icons.translate, size: 16),
                label: const Text('Translate → EN'),
                onPressed: _busy ? null : () => _run(DocAiMode.translate, lang: 'English')),
            ActionChip(
                avatar: const Icon(Icons.translate, size: 16),
                label: const Text('Translate → Urdu'),
                onPressed: _busy ? null : () => _run(DocAiMode.translate, lang: 'Urdu')),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            minLines: 1,
            maxLines: 3,
            textInputAction: TextInputAction.send,
            decoration: InputDecoration(
              hintText: 'Ask anything about this page…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.send),
                onPressed: _busy || _ctrl.text.trim().isEmpty
                    ? null
                    : () => _run(DocAiMode.ask, question: _ctrl.text.trim()),
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (q) => q.trim().isEmpty ? null : _run(DocAiMode.ask, question: q.trim()),
          ),
          const SizedBox(height: 14),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null && !_busy)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!)),
                if (widget.onUpgrade != null && _error!.contains('Pro'))
                  TextButton(onPressed: widget.onUpgrade, child: const Text('Upgrade')),
              ]),
            ),
          if (_answer != null && !_busy) ...[
            SelectableText(_answer!, style: const TextStyle(height: 1.4)),
            if (_truncated)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('(Long document — answered from a portion. Ask about a specific page for more.)',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ),
          ],
        ],
      ),
    );
  }
}
