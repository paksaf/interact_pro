/// One message in a support conversation.
///
/// `role` is one of:
///   user   — typed by the signed-in user
///   ai     — DeepSeek auto-response (server-side composed)
///   admin  — typed by an Interact Pro operator
///   system — server-generated note (e.g. SLA prompt)
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String role;
  final String body;
  final DateTime createdAt;

  bool get isFromUser => role == 'user';

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        role: j['role'] as String,
        body: j['body'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

/// Conversation metadata. There's one open conversation per user at a
/// time; the chat screen always opens "the" conversation (creating it
/// on first POST if needed).
class ChatConversation {
  const ChatConversation({
    required this.id,
    required this.status,
    this.title,
    this.handoffAt,
  });

  final String id;
  final String status;
  final String? title;
  final DateTime? handoffAt;

  /// True iff the conversation is waiting for a human admin to reply.
  bool get isWaitingForAdmin => status == 'admin_handoff';

  factory ChatConversation.fromJson(Map<String, dynamic> j) =>
      ChatConversation(
        id: j['id'] as String,
        status: j['status'] as String,
        title: j['title'] as String?,
        handoffAt: j['handoff_at'] == null
            ? null
            : DateTime.parse(j['handoff_at'] as String),
      );
}
