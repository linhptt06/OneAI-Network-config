import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'agent_protocol.dart';

/// Carries one request to the agent and returns its parsed `result`.
///
/// An interface rather than a concrete class so the client can be driven by a
/// recorded-response fake in tests, and so a future HTTP or ubus transport can
/// be dropped in without touching the client.
abstract class AgentTransport {
  Future<Map<String, dynamic>> send(Map<String, dynamic> request);
}

/// Runs the agent over the existing SSH connection, one process per request.
///
/// The request is written to the agent's stdin and the reply read from its
/// stdout. Passing the payload this way rather than as a command argument
/// means no user or model supplied value is ever interpolated into a shell
/// command line, so quoting bugs cannot become command injection.
class SshAgentTransport implements AgentTransport {
  SshAgentTransport(
    this._client, {
    this.agentPath = '/usr/libexec/rpcd/netagent',
    this.timeout = const Duration(seconds: 30),
  });

  final SSHClient _client;

  /// Location of the agent executable on the device. The default follows the
  /// rpcd plugin convention so the same binary can later be exposed over ubus
  /// without being moved.
  final String agentPath;

  final Duration timeout;

  @override
  Future<Map<String, dynamic>> send(Map<String, dynamic> request) async {
    //Validate chống shell injection, chỉ chấp nhận ký tự thường a-z và dấu gạch dưới
    //method là thành phần được đưa vào chuỗi lệnh SSH trên terminal nên validate lại đi không chèn ký tự độc
    final method = request['method'];
    if (method is! String || method.isEmpty) {
      throw ArgumentError('Yêu cầu thiếu trường "method".');
    }

    // The method name is the only thing on the command line. It comes from
    // the AgentMethod enum, never from model output, and is checked here so a
    // future caller cannot widen that guarantee by accident.
    if (!RegExp(r'^[a-z_]+$').hasMatch(method)) {
      throw ArgumentError('Tên method không hợp lệ: $method');
    }

    //Thực thi tiến trình SSH
    final session = await _client.execute('$agentPath call $method');

    //Đọc và ghi dữ liệu thông qua stdin và stdout/stderr
    //Chuyển toàn bộ request thành chuỗi JSON và đẩy qua stdin của tiến trình SSH
    final stdoutBytes = BytesBuilder();
    final stderrBytes = BytesBuilder();
    final collecting = Future.wait([
      session.stdout.forEach(stdoutBytes.add),
      session.stderr.forEach(stderrBytes.add),
    ]);

    session.stdin.add(Uint8List.fromList(utf8.encode(jsonEncode(request))));
    // The agent reads until EOF, so stdin must be closed or both sides wait
    // for each other until the timeout fires.
    await session.stdin.close();
    //Xử lý timeout khi agent không phản hồi. Nếu agent bị treo hoặc không phản hồi thì đóng phiên làm việc
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
      // A missing agent surfaces here as an empty stdout plus a shell error,
      // which is worth naming explicitly: it is the expected state before the
      // agent has been installed.
      throw AgentProtocolException(
        stderr.contains('not found')
            ? 'Chưa cài agent trên thiết bị ($agentPath).'
            : 'Agent không trả về gì (exit ${session.exitCode}).',
        rawResponse: stderr.isEmpty ? null : stderr,
      );
    }

    return decodeEnvelope(stdout); //trả về dữ liệu dạng JSON nếu hợp lệ, gửi lỗi nếu không hợp lệ
  }
}

/// In-memory transport for tests and for exercising the client before the
/// agent exists. Giả lập môi trường transport và phục vụ kiểm thử
class FakeAgentTransport implements AgentTransport {
  FakeAgentTransport(this._handler);

  /// Receives the request and returns the full envelope, so tests can produce
  /// malformed and error replies as easily as successful ones.
  final Map<String, dynamic> Function(Map<String, dynamic> request) _handler;

  /// Every request seen, in order, for assertions.
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<Map<String, dynamic>> send(Map<String, dynamic> request) async {
    requests.add(request);
    return decodeEnvelope(jsonEncode(_handler(request)));
  }
}
