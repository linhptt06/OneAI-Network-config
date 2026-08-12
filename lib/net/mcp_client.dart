import 'dart:convert';

import 'agent_protocol.dart';
import 'mcp_transport.dart';

/// What the router said about itself when the session opened.
class McpServerInfo {
  const McpServerInfo({
    required this.toolNames,
    this.name,
    this.version,
    this.protocolVersion,
  });

  /// Tool **names** only.
  ///
  /// The server does send a `description` for every tool, and it is dropped on
  /// purpose. Descriptions are rendered into the model's prompt, so accepting
  /// them from the device would let a compromised router write into the model's
  /// context. The app owns every word the model reads; the device only gets to
  /// say which of the app's tools it supports. Same rule as [negotiateTools] in
  /// `agent_client.dart`.
  final Set<String> toolNames;

  final String? name;
  final String? version;
  final String? protocolVersion;
}

/// Codes that mean the router itself is unhealthy rather than the model having
/// asked for the wrong thing.
///
/// The distinction matters for what the model does next: a bad section name is
/// worth retrying with a different name, a dead ubus is not.
const Set<String> kRouterFaultCodes = {
  'backend_unavailable',
  'backend_failed',
  'backend_value_too_long',
  'invalid_tool_response',
};

/// Codes that say nothing at all about the cause.
///
/// `run_tool()` on the router treats a non-zero exit status as failure and
/// replaces the tool's stdout with a generic `tool_failed` — discarding the
/// precise `{"status":"error","error":{"code":"section_not_found"}}` the tool
/// had just printed. A mistyped section name and a dead ubus therefore arrive
/// here indistinguishable.
///
/// Callers must offer the model both readings rather than pick one: guessing
/// "router is broken" tells it to stop when a second name would have worked,
/// and that is exactly how a turn stalls.
const Set<String> kAmbiguousFailureCodes = {'tool_failed'};

bool isRouterFault(String code) => kRouterFaultCodes.contains(code);

bool isAmbiguousFailure(String code) => kAmbiguousFailureCodes.contains(code);

/// Drives the MCP server on the router.
///
/// Holds no device knowledge of its own: which UCI keys a tool reads, and how a
/// given firmware exposes them, is the agent's business. This class only moves
/// typed requests and results across the boundary — and unwraps the two layers
/// of envelope the server wraps every answer in.
class McpClient {
  McpClient(this._transport);

  final McpTransport _transport;

  int _nextId = 1;
  McpServerInfo? _server;
  McpServerInfo? get server => _server;

  /// Opens the session: `initialize` and `tools/list` in **one** exec.
  ///
  /// The server does not gate on `initialize` — `handle_request` dispatches on
  /// the method name with no state of its own — but sending it costs nothing
  /// here and gives the identity fields the app used to probe for by hand.
  Future<McpServerInfo> connect() async {
    final initialize = _request('initialize');
    final listTools = _request('tools/list');

    final replies = await _transport.send([initialize, listTools]);
    final initResult = _resultOf(replies[0], initialize['id'] as int);
    final listResult = _resultOf(replies[1], listTools['id'] as int);

    final rawTools = listResult['tools'];
    if (rawTools is! List) {
      throw AgentProtocolException(
        'Phản hồi tools/list thiếu trường "tools".',
      );
    }

    final serverInfo = initResult['serverInfo'];
    final server = McpServerInfo(
      toolNames: {
        for (final tool in rawTools)
          if (tool is Map<String, dynamic> && tool['name'] is String)
            tool['name'] as String,
      },
      name: serverInfo is Map<String, dynamic>
          ? serverInfo['name'] as String?
          : null,
      version: serverInfo is Map<String, dynamic>
          ? serverInfo['version'] as String?
          : null,
      protocolVersion: initResult['protocolVersion'] as String?,
    );

    _server = server;
    return server;
  }

  /// Runs one read-only tool and returns its `data` object.
  ///
  /// [arguments] must contain exactly the parameters the tool declares: the
  /// server rejects any extra field outright (`additionalProperties: false`,
  /// enforced again by `object_has_only_argument`). Filtering belongs to the
  /// caller, which knows each tool's single parameter.
  Future<Map<String, dynamic>> callTool(
    String name, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final server = _server;
    if (server == null) {
      throw StateError('Phải gọi connect() trước khi dùng tool.');
    }
    if (!server.toolNames.contains(name)) {
      throw AgentErrorException(
        'unsupported_tool',
        'Thiết bị này không hỗ trợ "$name".',
      );
    }

    final request = _request(
      'tools/call',
      params: {'name': name, 'arguments': arguments},
    );
    final replies = await _transport.send([request]);
    final result = _resultOf(replies.single, request['id'] as int);
    return _unwrapToolResult(result);
  }

  Map<String, dynamic> _request(String method, {Map<String, dynamic>? params}) =>
      {
        'jsonrpc': '2.0',
        'id': _nextId++,
        'method': method,
        'params': ?params,
      };

  /// Peels the JSON-RPC envelope, checking that the reply belongs to the
  /// request that asked for it.
  Map<String, dynamic> _resultOf(Map<String, dynamic> reply, int expectedId) {
    final error = reply['error'];
    if (error is Map<String, dynamic>) {
      throw AgentProtocolException(
        'Agent từ chối yêu cầu: '
        '${error['message'] ?? 'không rõ nguyên nhân'} '
        '(code ${error['code']})',
      );
    }

    // Pairing is by position today because each batch is small and ordered,
    // but the id is what actually proves it. Checked so a future long-lived
    // session cannot silently hand one tool's answer to another tool.
    final id = reply['id'];
    if (id != expectedId) {
      throw AgentProtocolException(
        'Phản hồi lệch id: nhận $id, mong đợi $expectedId.',
      );
    }

    final result = reply['result'];
    if (result is! Map<String, dynamic>) {
      throw AgentProtocolException('Phản hồi thiếu trường "result".');
    }
    return result;
  }

  /// Peels the second envelope: the tool's own JSON, carried as **text** inside
  /// the MCP content array.
  ///
  /// `isError` is deliberately ignored. The server builds tool failures with
  /// the same `new_text_result` helper it uses for successes, so that flag
  /// reads `false` even when the tool failed; only `status` inside the text
  /// tells the truth.
  Map<String, dynamic> _unwrapToolResult(Map<String, dynamic> result) {
    final content = result['content'];
    if (content is! List || content.isEmpty) {
      throw AgentProtocolException('Kết quả tool không có phần "content".');
    }
    final first = content.first;
    if (first is! Map<String, dynamic> || first['text'] is! String) {
      throw AgentProtocolException('Kết quả tool không có phần text.');
    }

    final Object? envelope;
    try {
      envelope = jsonDecode(first['text'] as String);
    } catch (error) {
      throw AgentProtocolException(
        'Không phân tích được JSON của tool: $error',
        rawResponse: first['text'] as String,
      );
    }
    if (envelope is! Map<String, dynamic>) {
      throw AgentProtocolException(
        'Tool trả về ${envelope.runtimeType}, mong đợi một object JSON.',
      );
    }

    final status = envelope['status'];
    if (status == 'error') {
      final error = envelope['error'];
      throw AgentErrorException(
        error is Map<String, dynamic>
            ? error['code']?.toString() ?? 'unknown'
            : 'unknown',
        error is Map<String, dynamic>
            ? error['message']?.toString() ?? 'Tool báo lỗi không rõ nguyên nhân.'
            : 'Tool báo lỗi không rõ nguyên nhân.',
      );
    }
    if (status != 'ok') {
      throw AgentProtocolException('Tool trả về status không hợp lệ: $status');
    }

    final data = envelope['data'];
    return data is Map<String, dynamic> ? data : const {};
  }
}
