import 'package:chatbot/data/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

void main() {
  group('StoredMessage.toLlamaMessage', () {
    StoredMessage make({
      required StoredMessageKind kind,
      String content = '',
      String? toolName,
      String? toolCallId,
      String? toolArgumentsJson,
    }) => StoredMessage(
      id: 1,
      conversationId: 1,
      kind: kind,
      content: content,
      toolName: toolName,
      toolCallId: toolCallId,
      toolArgumentsJson: toolArgumentsJson,
      createdAt: DateTime(2026),
    );

    test('maps a user row to a user-role message', () {
      final message = make(
        kind: StoredMessageKind.user,
        content: 'Mấy giờ rồi?',
      ).toLlamaMessage();

      expect(message.role, LlamaChatRole.user);
      expect(message.content, 'Mấy giờ rồi?');
    });

    test('replays a tool call as an assistant tool_calls message', () {
      final message = make(
        kind: StoredMessageKind.toolCall,
        toolName: 'calculate',
        toolCallId: 'call_0',
        toolArgumentsJson: '{"expression":"2+2"}',
      ).toLlamaMessage();

      final json = message.toJson();
      expect(json['role'], 'assistant');
      expect(json['tool_calls'], isA<List<dynamic>>());

      final call = message.parts.whereType<LlamaToolCallContent>().single;
      expect(call.name, 'calculate');
      expect(call.arguments, {'expression': '2+2'});
    });

    test('replays a tool result as a tool-role message', () {
      final message = make(
        kind: StoredMessageKind.toolResult,
        content: '{"result":4}',
        toolName: 'calculate',
        toolCallId: 'call_0',
      ).toLlamaMessage();

      final json = message.toJson();
      expect(json['role'], 'tool');
      expect(json['tool_call_id'], 'call_0');
      expect(json['name'], 'calculate');
      expect(json['content'], '{"result":4}');
    });

    test('falls back to empty arguments when the JSON is malformed', () {
      final message = make(
        kind: StoredMessageKind.toolCall,
        toolName: 'calculate',
        toolArgumentsJson: '{not json',
      ).toLlamaMessage();

      final call = message.parts.whereType<LlamaToolCallContent>().single;
      expect(call.arguments, isEmpty);
    });
  });
}
