import 'dart:convert';

import 'package:chatbot/net/agent_protocol.dart';
import 'package:chatbot/net/mcp_client.dart';
import 'package:chatbot/net/mcp_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dựng đúng hình dạng phản hồi `new_text_result()` sinh ra trên router: JSON
/// của chính tool nằm dạng *chuỗi* trong mảng content của MCP.
Map<String, dynamic> textResult(int id, Map<String, dynamic> toolEnvelope) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': {
    'content': [
      {'type': 'text', 'text': jsonEncode(toolEnvelope)},
    ],
    // Luôn false, kể cả khi lỗi — xem ghi chú ở _unwrapToolResult.
    'isError': false,
  },
};

Map<String, dynamic> listResult(int id, List<String> names) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': {
    'tools': [
      for (final name in names)
        {
          'name': name,
          // Thiết bị có gửi mô tả. Tuyệt đối không được dùng chúng.
          'description': 'mô tả do THIẾT BỊ cung cấp',
          'inputSchema': {'type': 'object'},
        },
    ],
  },
};

Map<String, dynamic> initResult(int id) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': {
    'protocolVersion': '2024-11-05',
    'serverInfo': {'name': 'router-agent-c', 'version': '0.1.0'},
    'capabilities': {'tools': {}},
  },
};

/// Transport trả lời `initialize` và `tools/list` như bình thường, còn mọi
/// `tools/call` thì giao cho [onCall].
FakeMcpTransport transportWith({
  List<String> tools = const [
    'traffic_stats',
    'network_get',
    'network_list',
    'route_info',
    'wifi_get',
  ],
  Map<String, dynamic> Function(Map<String, dynamic> request)? onCall,
}) {
  return FakeMcpTransport((request) {
    final id = request['id'] as int;
    switch (request['method']) {
      case 'initialize':
        return initResult(id);
      case 'tools/list':
        return listResult(id, tools);
      default:
        return onCall!(request);
    }
  });
}

Future<McpClient> connected({
  List<String> tools = const [
    'traffic_stats',
    'network_get',
    'network_list',
    'route_info',
    'wifi_get',
  ],
  Map<String, dynamic> Function(Map<String, dynamic> request)? onCall,
}) async {
  final client = McpClient(transportWith(tools: tools, onCall: onCall));
  await client.connect();
  return client;
}

void main() {
  group('session opening', () {
    test('takes one exec for initialize and tools/list', () async {
      final transport = transportWith();
      final client = McpClient(transport);

      final server = await client.connect();

      // Hai yêu cầu đi chung một lần gọi: server đọc stdin theo vòng lặp nên
      // mở exec SSH thứ hai là phí một round trip.
      expect(transport.requests.map((r) => r['method']), [
        'initialize',
        'tools/list',
      ]);
      expect(server.name, 'router-agent-c');
      expect(server.protocolVersion, '2024-11-05');
    });

    test('keeps names and throws the device descriptions away', () async {
      final server = (await connected()).server!;

      expect(server.toolNames, {
        'traffic_stats',
        'network_get',
        'network_list',
        'route_info',
        'wifi_get',
      });
      // McpServerInfo không có chỗ chứa mô tả do thiết bị gửi — đó chính là
      // mục đích: không chữ nào router viết chạm được vào prompt.
    });
  });

  group('tool results', () {
    test('unwraps both envelopes down to data', () async {
      final client = await connected(
        onCall: (request) => textResult(request['id'] as int, {
          'status': 'ok',
          'data': {'interface': 'lan', 'proto': 'static'},
        }),
      );

      final data = await client.callTool('network_get', {'interface': 'lan'});
      expect(data, {'interface': 'lan', 'proto': 'static'});
    });

    test('preserves an array payload from network_list', () async {
      final client = await connected(
        onCall: (request) => textResult(request['id'] as int, {
          'status': 'ok',
          'data': [
            {'interface': 'lan'},
            {'interface': 'wan'},
          ],
        }),
      );

      final result = await client.callTool('network_list');

      expect(result['items'], [
        {'interface': 'lan'},
        {'interface': 'wan'},
      ]);
    });

    test('a tool failure is an error even though isError says false', () async {
      // Router dựng lỗi bằng cùng helper với thành công nên cờ ở mức MCP vô
      // dụng. Chỉ `status` bên trong text mới đúng; hiểu sai chỗ này là đưa
      // cho model một object lỗi như thể đó là cấu hình.
      final client = await connected(
        onCall: (request) => textResult(request['id'] as int, {
          'status': 'error',
          'error': {
            'code': 'section_not_found',
            'message': 'Wireless section was not found',
          },
        }),
      );

      await expectLater(
        client.callTool('wifi_get', {'section': 'default_radio0'}),
        throwsA(
          isA<AgentErrorException>().having(
            (e) => e.code,
            'code',
            'section_not_found',
          ),
        ),
      );
    });

    test('separates a wrong argument from a sick router', () {
      // Việc model nên làm tiếp là khác nhau: thử tên khác, hay dừng và báo.
      // Chia nhóm chính là thứ phân biệt hai trường hợp.
      expect(isRouterFault('section_not_found'), isFalse);
      expect(isRouterFault('invalid_interface'), isFalse);
      expect(isRouterFault('backend_unavailable'), isTrue);
      expect(isRouterFault('backend_failed'), isTrue);
    });

    test('tool_failed is ambiguous, not a router fault', () {
      // run_tool() trên router vứt vỏ lỗi của chính tool và báo đúng một mã
      // cho mọi thứ. Hiểu nó thành "router hỏng" sẽ bảo model dừng, trong khi
      // nguyên nhân thật chỉ là gõ sai tên section.
      expect(isAmbiguousFailure('tool_failed'), isTrue);
      expect(isRouterFault('tool_failed'), isFalse);

      // Không mã nào khác nhập nhằng: các mã còn lại đều chỉ rõ nguyên nhân.
      expect(isAmbiguousFailure('section_not_found'), isFalse);
      expect(isAmbiguousFailure('backend_unavailable'), isFalse);
    });

    test('rejects a status the contract does not define', () async {
      final client = await connected(
        onCall: (request) =>
            textResult(request['id'] as int, {'status': 'maybe'}),
      );

      await expectLater(
        client.callTool('route_info'),
        throwsA(isA<AgentProtocolException>()),
      );
    });

    test('sends arguments verbatim, with no field of its own', () async {
      final transport = transportWith(
        onCall: (request) =>
            textResult(request['id'] as int, {'status': 'ok', 'data': {}}),
      );
      final client = McpClient(transport);
      await client.connect();

      await client.callTool('wifi_get', {'section': 'ra0'});

      // Server từ chối mọi field lạ, nên client không được thêm thắt gì vào
      // payload.
      final params = transport.requests.last['params'] as Map<String, dynamic>;
      expect(params['name'], 'wifi_get');
      expect(params['arguments'], {'section': 'ra0'});
    });

    test('calls network_list without inventing arguments', () async {
      final transport = transportWith(
        onCall: (request) =>
            textResult(request['id'] as int, {'status': 'ok', 'data': {}}),
      );
      final client = McpClient(transport);
      await client.connect();

      await client.callTool('network_list');

      final params = transport.requests.last['params'] as Map<String, dynamic>;
      expect(params['name'], 'network_list');
      expect(params['arguments'], isEmpty);
    });
  });

  group('protocol failures', () {
    test('a JSON-RPC error is not mistaken for a result', () async {
      final client = await connected(
        onCall: (request) => {
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32601, 'message': 'Method not found.'},
        },
      );

      await expectLater(
        client.callTool('route_info'),
        throwsA(isA<AgentProtocolException>()),
      );
    });

    test('a reply carrying the wrong id is refused', () async {
      final client = await connected(
        onCall: (request) => textResult((request['id'] as int) + 99, {
          'status': 'ok',
          'data': {},
        }),
      );

      await expectLater(
        client.callTool('route_info'),
        throwsA(isA<AgentProtocolException>()),
      );
    });

    test('refuses a tool the device never advertised', () async {
      final client = await connected(tools: ['route_info']);

      await expectLater(
        client.callTool('wifi_get', {'section': 'ra0'}),
        throwsA(
          isA<AgentErrorException>().having(
            (e) => e.code,
            'code',
            'unsupported_tool',
          ),
        ),
      );
    });

    test('requires the session to be opened first', () async {
      final client = McpClient(transportWith());

      await expectLater(
        client.callTool('route_info'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('decodeJsonRpcLines', () {
    test('skips banner noise printed before the payload', () {
      final replies = decodeJsonRpcLines(
        'Welcome to OpenWrt\n{"jsonrpc":"2.0","id":1,"result":{}}\n',
        expected: 1,
      );

      expect(replies.single['id'], 1);
    });

    test('returns one reply per line, in order', () {
      final replies = decodeJsonRpcLines(
        '{"jsonrpc":"2.0","id":1,"result":{}}\n'
        '{"jsonrpc":"2.0","id":2,"result":{}}\n',
        expected: 2,
      );

      expect(replies.map((r) => r['id']), [1, 2]);
    });

    test('a truncated batch is fatal, not silently short', () {
      // Bên gọi ghép phản hồi với yêu cầu theo vị trí, nên thiếu một dòng là
      // mọi câu trả lời lệch sang câu hỏi khác.
      expect(
        () => decodeJsonRpcLines(
          '{"jsonrpc":"2.0","id":1,"result":{}}\n',
          expected: 2,
        ),
        throwsA(isA<AgentProtocolException>()),
      );
    });
  });
}
