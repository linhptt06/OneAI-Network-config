import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// A stored conversation (one chat thread).
class Conversation {
  final int id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromRow(Map<String, Object?> row) => Conversation(
    id: row['id'] as int,
    title: row['title'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
  );
}

/// What kind of row a stored message is.
///
/// This is a superset of [LlamaChatRole]: tool calls are stored as their own
/// kind so the UI can render "the model asked to run X" separately from the
/// assistant's prose, while both still map back to an assistant-role message
/// when the history is replayed into the engine.
enum StoredMessageKind { user, assistant, toolCall, toolResult }

/// A single persisted message.
///
/// llamadart's [ChatSession] keeps history in memory only, so this app owns the
/// full history in SQLite and replays it into [LlamaEngine.create] on every
/// turn. [toLlamaMessage] is the bridge back to the engine's message type.
class StoredMessage {
  final int id;
  final int conversationId;
  final StoredMessageKind kind;

  /// Prose content for user/assistant rows, or the tool result payload
  /// (JSON-encoded) for tool-result rows.
  final String content;

  /// Model reasoning, when the model emits it. Kept out of [content] so it can
  /// be collapsed in the UI and excluded from the replayed prompt.
  final String? reasoning;

  /// Tool name, for [StoredMessageKind.toolCall] and
  /// [StoredMessageKind.toolResult] rows.
  final String? toolName;

  /// Tool call id, used to pair a call with its result.
  final String? toolCallId;

  /// Raw JSON arguments the model generated, for tool-call rows.
  final String? toolArgumentsJson;

  final DateTime createdAt;

  const StoredMessage({
    required this.id,
    required this.conversationId,
    required this.kind,
    required this.content,
    required this.createdAt,
    this.reasoning,
    this.toolName,
    this.toolCallId,
    this.toolArgumentsJson,
  });

  factory StoredMessage.fromRow(Map<String, Object?> row) => StoredMessage(
    id: row['id'] as int,
    conversationId: row['conversation_id'] as int,
    kind: StoredMessageKind.values.byName(row['kind'] as String),
    content: row['content'] as String,
    reasoning: row['reasoning'] as String?,
    toolName: row['tool_name'] as String?,
    toolCallId: row['tool_call_id'] as String?,
    toolArgumentsJson: row['tool_arguments'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
  );

  Map<String, Object?> get decodedArguments {
    final raw = toolArgumentsJson;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Converts this row back into the message type the engine consumes.
  LlamaChatMessage toLlamaMessage() {
    switch (kind) {
      case StoredMessageKind.user:
        return LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: content,
        );
      case StoredMessageKind.assistant:
        return LlamaChatMessage.fromText(
          role: LlamaChatRole.assistant,
          text: content,
        );
      case StoredMessageKind.toolCall:
        return LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            LlamaToolCallContent(
              id: toolCallId,
              name: toolName ?? '',
              arguments: Map<String, dynamic>.from(decodedArguments),
              rawJson: toolArgumentsJson ?? '{}',
            ),
          ],
        );
      case StoredMessageKind.toolResult:
        return LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(
              id: toolCallId,
              name: toolName ?? '',
              result: content,
            ),
          ],
        );
    }
  }
}
