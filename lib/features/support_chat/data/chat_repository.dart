import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../../auth/data/auth_api_client.dart';
import '../domain/chat_message.dart';

/// Wrapper around `pro.interactpak.com/api/chat/*`.
///
/// Endpoint contract (server side: server/pro-api/index.js):
///
///   GET  /api/chat/conversation
///     → { conversation, messages: [...] }
///
///   POST /api/chat/messages         body: { body }
///     → { userMessage, replies: [...] }
///       — `replies` may contain 0+ messages: usually 1 ai message,
///         OR 1 system handoff message when AI declined to answer,
///         OR 0 messages when the conversation is already in admin
///         handoff (server doesn't auto-respond while waiting on a
///         human).
class ChatRepository {
  ChatRepository(this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final AuthApiClient _auth;
  final http.Client _http;

  String get _baseUrl => _auth.baseUrl;

  Future<Result<ChatThread>> loadConversation() async {
    final token = await _auth.bearerToken();
    if (token == null) {
      return const Result.err(AuthFailure('Sign in to use chat support.'));
    }
    try {
      final resp = await _http.get(
        Uri.parse('$_baseUrl/api/chat/conversation'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 401) {
        return const Result.err(AuthFailure('Session expired.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(
            NetworkFailure('Chat fetch failed (${resp.statusCode}).'),);
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Result.ok(ChatThread(
        conversation: ChatConversation.fromJson(
          json['conversation'] as Map<String, dynamic>,
        ),
        messages: (json['messages'] as List<dynamic>)
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      ),);
    } catch (e, st) {
      appLogger.e('chat loadConversation failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Could not load chat', cause: e));
    }
  }

  Future<Result<ChatPostResult>> sendMessage(String body) async {
    final token = await _auth.bearerToken();
    if (token == null) {
      return const Result.err(AuthFailure('Sign in to use chat support.'));
    }
    try {
      final resp = await _http
          .post(
            Uri.parse('$_baseUrl/api/chat/messages'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'body': body}),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 401) {
        return const Result.err(AuthFailure('Session expired.'));
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return Result.err(
            NetworkFailure('Send failed (${resp.statusCode}).'),);
      }
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return Result.ok(ChatPostResult(
        userMessage: ChatMessage.fromJson(
          json['userMessage'] as Map<String, dynamic>,
        ),
        replies: (json['replies'] as List<dynamic>)
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      ),);
    } catch (e, st) {
      appLogger.e('chat sendMessage failed', error: e, stackTrace: st);
      return Result.err(NetworkFailure('Could not send', cause: e));
    }
  }
}

class ChatThread {
  const ChatThread({required this.conversation, required this.messages});
  final ChatConversation conversation;
  final List<ChatMessage> messages;
}

class ChatPostResult {
  const ChatPostResult({required this.userMessage, required this.replies});
  final ChatMessage userMessage;
  final List<ChatMessage> replies;
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(authApiClientProvider));
});
