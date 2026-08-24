import 'dart:convert';

import 'agent_protocol.dart';
import 'mcp_transport.dart';

/// Những gì router tự khai khi mở phiên.
class McpServerInfo {
  const McpServerInfo({
    required this.toolNames,
    this.name,
    this.version,
    this.protocolVersion,
  });

  /// Chỉ **tên** tool.
  ///
  /// Server có gửi `description` cho từng tool và ta cố ý vứt đi. Mô tả sẽ đi
  /// vào prompt, nên nhận nó từ thiết bị đồng nghĩa cho một router bị chiếm
  /// quyền ghi thẳng vào context của model. App sở hữu mọi chữ model đọc;
  /// thiết bị chỉ được nói nó hỗ trợ tool nào của app.
  final Set<String> toolNames;

  final String? name;
  final String? version;
  final String? protocolVersion;
}

/// Các mã báo router đang trục trặc, chứ không phải model hỏi sai.
///
/// Phân biệt được mới biết model nên làm gì tiếp: sai tên section thì đáng thử
/// tên khác, ubus chết thì không.
///
/// [kUnsupportedToolCode] tách riêng, vì đổi tham số không làm một tool router
/// không có tự nhiên xuất hiện.
const Set<String> kRouterFaultCodes = {
  'backend_unavailable',
  'backend_failed',
  'backend_value_too_long',
  'invalid_tool_response',
};

/// Các mã không nói gì về nguyên nhân.
///
/// `run_tool()` trên router coi exit code khác 0 là thất bại và thay stdout
/// của tool bằng `tool_failed` chung chung, vứt mất mã lỗi chính xác tool vừa
/// in ra. Vì thế gõ sai tên section và ubus chết về đến đây giống hệt nhau.
///
/// Bên gọi phải đưa cả hai cách hiểu cho model chứ đừng chọn một: đoán "router
/// hỏng" sẽ bảo nó dừng, trong khi thử tên khác là xong.
const Set<String> kAmbiguousFailureCodes = {'tool_failed'};

bool isRouterFault(String code) => kRouterFaultCodes.contains(code);

bool isAmbiguousFailure(String code) => kAmbiguousFailureCodes.contains(code);

/// Điều khiển MCP server trên router.
///
/// Không tự biết gì về thiết bị: tool đọc key UCI nào, firmware phơi ra sao là
/// việc của agent. Lớp này chỉ chuyển yêu cầu và kết quả qua ranh giới, và bóc
/// hai lớp vỏ mà server bọc quanh mọi câu trả lời.
class McpClient {
  McpClient(this._transport);

  final McpTransport _transport;

  int _nextId = 1;
  McpServerInfo? _server;
  McpServerInfo? get server => _server;

  /// Mở phiên: `initialize` và `tools/list` trong **một** lần exec.
  ///
  /// Server không bắt buộc `initialize`, nhưng gửi kèm thì không tốn thêm gì
  /// mà lại lấy được thông tin danh tính app từng phải dò thủ công.
  Future<McpServerInfo> connect() async {
    final initialize = _request('initialize');
    final listTools = _request('tools/list');

    final replies = await _transport.send([initialize, listTools]);
    final initResult = _resultOf(replies[0], initialize['id'] as int);
    final listResult = _resultOf(replies[1], listTools['id'] as int);

    final rawTools = listResult['tools'];
    if (rawTools is! List) {
      throw AgentProtocolException('Phản hồi tools/list thiếu trường "tools".');
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

  /// Chạy một tool trên router và trả về object `data` của nó.
  ///
  /// [arguments] phải chứa đúng các tham số tool khai báo: server từ chối
  /// thẳng mọi field thừa. Việc lọc thuộc về bên gọi, nơi biết tool có tham
  /// số nào.
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
        kUnsupportedToolCode,
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

  Map<String, dynamic> _request(
    String method, {
    Map<String, dynamic>? params,
  }) => {
    'jsonrpc': '2.0',
    'id': _nextId++,
    'method': method,
    'params': ?params,
  };

  /// Bóc vỏ JSON-RPC, kiểm tra phản hồi đúng là của yêu cầu đã gửi.
  Map<String, dynamic> _resultOf(Map<String, dynamic> reply, int expectedId) {
    final error = reply['error'];
    if (error is Map<String, dynamic>) {
      throw AgentProtocolException(
        'Agent từ chối yêu cầu: '
        '${error['message'] ?? 'không rõ nguyên nhân'} '
        '(code ${error['code']})',
      );
    }

    // Hiện ghép theo vị trí vì mỗi batch nhỏ và có thứ tự, nhưng id mới là
    // bằng chứng thật. Kiểm để phiên dài sau này không trao nhầm kết quả.
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

  /// Bóc lớp vỏ thứ hai: JSON của chính tool, nằm dạng **text** trong mảng
  /// content của MCP.
  ///
  /// Cố ý bỏ qua `isError`: server dựng lỗi bằng cùng helper với thành công
  /// nên cờ đó luôn `false`; chỉ `status` bên trong text mới nói thật.
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
            ? error['message']?.toString() ??
                  'Tool báo lỗi không rõ nguyên nhân.'
            : 'Tool báo lỗi không rõ nguyên nhân.',
      );
    }
    if (status != 'ok') {
      throw AgentProtocolException('Tool trả về status không hợp lệ: $status');
    }

    final data = envelope['data'];
    if (data is Map<String, dynamic>) return data;
    // Phần lớn tool trả object, riêng network_list cố ý trả mảng. Đừng ép
    // mảng đó thành {}: từng khiến router có sẵn LAN và WAN trông như không
    // có interface nào.
    if (data is List) return {'items': data};
    throw AgentProtocolException(
      'Tool trả về data không hợp lệ: mong đợi object hoặc mảng JSON.',
    );
  }
}
