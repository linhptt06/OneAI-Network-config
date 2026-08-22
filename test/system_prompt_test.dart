import 'package:chatbot/llm/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('directs a complete LAN IP request to the safe write flow', () {
    expect(
      kSystemPrompt,
      contains('network_set_preview là luồng ghi cấu hình'),
    );
    expect(kSystemPrompt, contains('PHẢI gọi ngay network_set_preview'));
    expect(kSystemPrompt, contains('Không gọi thao tác áp dụng nội bộ'));
    expect(kSystemPrompt, isNot(contains('network_set_apply')));
    expect(
      kSystemPrompt,
      contains('chỉ trả lời theo đúng kết quả tool trả về'),
    );
    expect(kSystemPrompt, contains('status confirmed'));
  });
}
