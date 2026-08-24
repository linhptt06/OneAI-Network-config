import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'agent_protocol.dart';

/// Chuyển yêu cầu JSON-RPC tới MCP server trên router.
///
/// [send] nhận cả danh sách chứ không nhận từng yêu cầu, vì server đọc stdin
/// theo vòng lặp: nhiều yêu cầu đi chung một kênh SSH exec và trả về mỗi dòng
/// một phản hồi, đúng thứ tự. Mở kênh riêng cho từng yêu cầu tốn thêm round
/// trip mà router khó chịu nổi.
///
/// Để dạng interface để test cắm được transport giả, và sau này thêm transport
/// ubus mà không phải sửa client.
abstract class McpTransport {
  Future<List<Map<String, dynamic>>> send(List<Map<String, dynamic>> requests);
}

/// Chạy `mcp_stdio_server` qua kết nối SSH sẵn có.
///
/// Không gì do người dùng hay model cung cấp chạm tới dòng lệnh: đường dẫn
/// thực thi là hằng số, mọi tham số đi trong thân JSON trên stdin, nên lỗi
/// escape không thể thành command injection.
class SshMcpTransport implements McpTransport {
  SshMcpTransport(
    this._client, {
    this.serverPath = '/usr/libexec/router-agent/mcp_stdio_server',
    this.timeout = const Duration(seconds: 30),
  });

  final SSHClient _client;

  /// Nơi `make install` đặt server; repo agent cài mọi tool vào
  /// `/usr/libexec/router-agent/`.
  final String serverPath;

  final Duration timeout;

  @override
  Future<List<Map<String, dynamic>>> send(
    List<Map<String, dynamic>> requests,
  ) async {
    if (requests.isEmpty) return const [];

    final session = await _client.execute(serverPath);

    final stdoutBytes = BytesBuilder();
    final stderrBytes = BytesBuilder();
    final collecting = Future.wait([
      session.stdout.forEach(stdoutBytes.add),
      session.stderr.forEach(stderrBytes.add),
    ]);

    // Vòng đọc của server từ chối dòng không kết thúc bằng `\n`, nên ký tự
    // xuống dòng là một phần hợp đồng chứ không phải cho đẹp.
    final payload = StringBuffer();
    for (final request in requests) {
      payload.write(jsonEncode(request));
      payload.write('\n');
    }
    session.stdin.add(Uint8List.fromList(utf8.encode(payload.toString())));
    // Server đọc tới EOF, nên phải đóng stdin, nếu không hai bên chờ nhau tới
    // khi hết timeout.
    await session.stdin.close();

    try {
      await collecting.timeout(timeout);
      await session.waitForExit(timeout: timeout);
    } on TimeoutException {
      session.close();
      throw AgentProtocolException(
        'Agent không phản hồi sau ${timeout.inSeconds}s.',
      );
    }

    final stdout = utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true);
    final stderr = utf8.decode(stderrBytes.takeBytes(), allowMalformed: true);

    if (stdout.trim().isEmpty) {
      // Chưa cài agent thì hiện ra ở đây thành stdout rỗng kèm lỗi shell —
      // đáng gọi tên rõ ràng vì đó là trạng thái bình thường lúc chưa cài.
      throw AgentProtocolException(
        stderr.contains('not found')
            ? 'Chưa cài agent trên thiết bị ($serverPath).'
            : 'Agent không trả về gì (exit ${session.exitCode}).',
        rawResponse: stderr.isEmpty ? null : stderr,
      );
    }

    return decodeJsonRpcLines(stdout, expected: requests.length);
  }
}

/// Tách stdout của server thành mỗi dòng một phản hồi đã giải mã.
///
/// Dòng không phải object JSON thì bỏ qua chứ không coi là lỗi: banner đăng
/// nhập hay cảnh báo busybox chỉ là nhiễu. Nhưng thiếu phản hồi là lỗi nặng,
/// vì bên gọi ghép phản hồi với yêu cầu theo vị trí.
List<Map<String, dynamic>> decodeJsonRpcLines(
  String stdout, {
  required int expected,
}) {
  final replies = <Map<String, dynamic>>[];

  for (final line in const LineSplitter().convert(stdout)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      continue;
    }
    if (decoded is Map<String, dynamic>) replies.add(decoded);
  }

  if (replies.length < expected) {
    throw AgentProtocolException(
      'Agent trả về ${replies.length} phản hồi, mong đợi $expected.',
      rawResponse: _truncate(stdout),
    );
  }
  return replies;
}

String _truncate(String value, [int max = 400]) =>
    value.length <= max ? value : '${value.substring(0, max)}…';

/// Transport trong bộ nhớ, cho test và để chạy thử client khi không có router.
class FakeMcpTransport implements McpTransport {
  FakeMcpTransport(this._handler);

  /// Nhận một yêu cầu và trả về nguyên vỏ JSON-RPC, để test dựng lỗi giao thức
  /// hay phản hồi hỏng dễ như dựng thành công.
  final Map<String, dynamic> Function(Map<String, dynamic> request) _handler;

  /// Mọi yêu cầu đã nhận, đúng thứ tự, để test kiểm chứng.
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<List<Map<String, dynamic>>> send(
    List<Map<String, dynamic>> batch,
  ) async {
    requests.addAll(batch);
    return batch.map(_handler).toList();
  }
}
