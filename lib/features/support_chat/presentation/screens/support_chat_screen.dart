import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_repository.dart';
import '../../domain/chat_message.dart';

/// Support chat — initial DeepSeek AI auto-reply, hand-off to admin
/// when the AI hedges. Floating chat icon on the home screen opens
/// this; users can also reach it from Settings → Help.
class SupportChatScreen extends ConsumerStatefulWidget {
  const SupportChatScreen({super.key});

  @override
  ConsumerState<SupportChatScreen> createState() => _SupportChatScreenState();
}

class _SupportChatScreenState extends ConsumerState<SupportChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatConversation? _convo;
  List<ChatMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(chatRepositoryProvider);
    final r = await repo.loadConversation();
    if (!mounted) return;
    r.fold(
      (thread) {
        setState(() {
          _loading = false;
          _convo = thread.conversation;
          _messages = thread.messages;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      },
      (failure) => setState(() {
        _loading = false;
        _error = failure.message;
      }),
    );
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    _input.clear();
    final repo = ref.read(chatRepositoryProvider);
    final r = await repo.sendMessage(text);
    if (!mounted) return;
    r.fold(
      (post) {
        setState(() {
          _sending = false;
          _messages = [..._messages, post.userMessage, ...post.replies];
          // Refresh convo status (it might have flipped to admin_handoff).
          if (post.replies.any((m) => m.role == 'system')) {
            _convo = ChatConversation(
              id: _convo?.id ?? '',
              status: 'admin_handoff',
              title: _convo?.title,
              handoffAt: DateTime.now(),
            );
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      },
      (failure) => setState(() {
        _sending = false;
        _error = failure.message;
        // Restore the user's text so they don't lose it.
        _input.text = text;
      }),
    );
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Support'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_convo?.isWaitingForAdmin == true)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: const Color(0xFFFFF1C7),
              child: const Row(
                children: [
                  Icon(Icons.schedule, size: 16,
                      color: Color(0xFF6B4500),),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Waiting for an admin — typical reply within 24 hours.',
                      style: TextStyle(
                        color: Color(0xFF6B4500),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_messages.isEmpty
                    ? _EmptyState()
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) =>
                            _Bubble(message: _messages[i]),
                      )),
          ),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(8),
              color: cs.errorContainer,
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: cs.onErrorContainer),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_error!,
                        style: TextStyle(color: cs.onErrorContainer),),
                  ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Ask anything about Interact Pro…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12,),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.support_agent_outlined, size: 80, color: cs.outline),
            const SizedBox(height: 12),
            Text('How can we help?',
                style: Theme.of(context).textTheme.titleMedium,),
            const SizedBox(height: 6),
            Text(
              'AI answers most questions instantly. If it can\'t, an admin '
              'jumps in within 24 hours.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = message.isFromUser;
    final isSystem = message.role == 'system';
    final isAdmin = message.role == 'admin';
    final isAi = message.role == 'ai';

    final bg = isUser
        ? cs.primary
        : isAdmin
            ? const Color(0xFFE0F2FE)
            : isSystem
                ? const Color(0xFFFFF1C7)
                : cs.surfaceContainerHighest;
    final fg = isUser
        ? cs.onPrimary
        : isAdmin
            ? const Color(0xFF0C4A6E)
            : isSystem
                ? const Color(0xFF6B4500)
                : cs.onSurface;
    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isUser ? 16 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 16),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: align,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          child: Container(
            decoration: BoxDecoration(color: bg, borderRadius: radius),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isAi || isAdmin || isSystem)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      isAdmin
                          ? 'Admin'
                          : isAi
                              ? 'Interact AI'
                              : 'System',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: fg.withOpacity(0.7),
                      ),
                    ),
                  ),
                SelectableText(
                  message.body,
                  style: TextStyle(color: fg, fontSize: 14, height: 1.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
