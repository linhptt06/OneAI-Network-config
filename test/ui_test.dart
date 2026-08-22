import 'package:chatbot/data/chat_models.dart';
import 'package:chatbot/ui/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StoredMessage message({
    required StoredMessageKind kind,
    required String content,
  }) => StoredMessage(
    id: 1,
    conversationId: 1,
    kind: kind,
    content: content,
    toolName: 'connect_device',
    toolCallId: 'call_0',
    toolArgumentsJson: '{"device":"oneai"}',
    createdAt: DateTime(2026),
  );

  Future<void> render(WidgetTester tester, StoredMessage value) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MessageBubble(message: value))),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a compact tool-call tile without raw arguments', (
    tester,
  ) async {
    await render(
      tester,
      message(kind: StoredMessageKind.toolCall, content: ''),
    );

    expect(find.text('Gọi công cụ: connect_device'), findsOneWidget);
    expect(find.textContaining('{"device"'), findsNothing);
  });

  testWidgets('shows an expandable, formatted tool result', (tester) async {
    await render(
      tester,
      message(
        kind: StoredMessageKind.toolResult,
        content: '{"connected":true,"device":"oneai"}',
      ),
    );

    await tester.tap(find.text('Kết quả: connect_device'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"connected": true'), findsOneWidget);
    expect(find.textContaining('"device": "oneai"'), findsOneWidget);
  });
}
