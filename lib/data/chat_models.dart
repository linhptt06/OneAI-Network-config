import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// Một hội thoại đã lưu (một luồng chat).
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

/// Loại của một bản ghi tin nhắn.
///
/// Rộng hơn [LlamaChatRole]: tool call được lưu thành loại riêng để UI hiển
/// thị "model xin chạy X" tách khỏi văn bản của trợ lý, dù khi phát lại vào
/// engine cả hai đều trở về vai assistant.
enum StoredMessageKind { user, assistant, toolCall, toolResult }

/// Một tin nhắn đã lưu.
///
/// [ChatSession] của llamadart chỉ giữ lịch sử trong RAM, nên app tự giữ toàn
/// bộ lịch sử trong SQLite và phát lại ở mỗi lượt. [toLlamaMessage] là cầu nối
/// trở về kiểu tin nhắn của engine.
class StoredMessage {
  final int id;
  final int conversationId;
  final StoredMessageKind kind;

  /// Văn bản với bản ghi user/assistant, hoặc payload JSON của kết quả tool.
  final String content;

  /// Phần suy luận của model, nếu có. Để riêng khỏi [content] để UI thu gọn
  /// được và không phát lại vào prompt.
  final String? reasoning;

  /// Tên tool, cho bản ghi [StoredMessageKind.toolCall] và
  /// [StoredMessageKind.toolResult].
  final String? toolName;

  /// Id của lời gọi tool, dùng để ghép lời gọi với kết quả.
  final String? toolCallId;

  /// Tham số JSON thô model sinh ra, cho bản ghi tool call.
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

  /// Chuyển bản ghi này về kiểu tin nhắn mà engine nhận.
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
