import 'dart:convert';

import 'package:chatbot/net/agent_protocol.dart';
import 'package:chatbot/net/mcp_client.dart';
import 'package:chatbot/net/mcp_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the reply shape `new_text_result()` produces on the router: the
/// tool's own JSON carried as a *string* inside the MCP content array.
Map<String, dynamic> textResult(int id, Map<String, dynamic> toolEnvelope) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': {
    'content': [
      {'type': 'text', 'text': jsonEncode(toolEnvelope)},
    ],
    // Always false, even for failures — see the note in _unwrapToolResult.
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
          // The device does send descriptions. They must never be used.
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

/// A transport that answers `initialize` and `tools/list` normally and defers
/// every `tools/call` to [onCall].
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

      // Both requests rode the same call: the server reads stdin in a loop, so
      // a second SSH exec would be a wasted round trip.
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
      // McpServerInfo has nowhere to put a device-supplied description, which
      // is the point: nothing the router writes can reach the model's prompt.
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

    test('a tool failure is an error even though isError says false', () async {
      // The router builds failures with the same helper as successes, so the
      // MCP-level flag is useless. Only `status` inside the text is truthful,
      // and getting this wrong hands the model an error object as if it were
      // configuration.
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
      // What the model should do next differs: retry with another name, or
      // stop and report. The split is what tells the two apart.
      expect(isRouterFault('section_not_found'), isFalse);
      expect(isRouterFault('invalid_interface'), isFalse);
      expect(isRouterFault('backend_unavailable'), isTrue);
      expect(isRouterFault('backend_failed'), isTrue);
    });

    test('tool_failed is ambiguous, not a router fault', () {
      // run_tool() on the router throws the tool's own error envelope away and
      // reports this one code for everything. Reading it as "router is broken"
      // told the model to stop when the real cause was a mistyped section name
      // that a second attempt would have fixed.
      expect(isAmbiguousFailure('tool_failed'), isTrue);
      expect(isRouterFault('tool_failed'), isFalse);

      // Nothing else is ambiguous: the other codes do identify their cause.
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

      // The server rejects any unexpected field, so the client must not
      // decorate the payload.
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
        onCall: (request) => textResult(
          (request['id'] as int) + 99,
          {'status': 'ok', 'data': {}},
        ),
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
      // Callers pair replies with requests by position, so a missing line
      // would otherwise shift every answer onto the wrong question.
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
