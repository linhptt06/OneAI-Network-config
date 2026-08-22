import 'package:chatbot/llm/tool_catalogue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

void main() {
  test('offers only app-defined tools advertised by the router', () {
    final tools = [
      ToolDefinition(
        name: 'network_get',
        description: 'Đọc mạng.',
        parameters: const [],
        handler: (_) async => const {},
      ),
      ToolDefinition(
        name: 'wifi_get',
        description: 'Đọc Wi-Fi.',
        parameters: const [],
        handler: (_) async => const {},
      ),
    ];

    final available = negotiateTools(tools, {'wifi_get', 'untrusted_tool'});

    expect(available.map((tool) => tool.name), ['wifi_get']);
  });
}
