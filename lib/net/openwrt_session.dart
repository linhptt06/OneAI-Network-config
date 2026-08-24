import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'device_profile.dart';

/// Kết quả của một lệnh chạy từ xa.
class CommandResult {
  const CommandResult({
    required this.command,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String command;
  final String stdout;
  final String stderr;
  final int? exitCode;

  bool get ok => exitCode == 0;
}

class OpenWrtException implements Exception {
  OpenWrtException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Một kết nối SSH đã xác thực tới một thiết bị OpenWrt.
///
/// Đây là tất cả những gì còn lại ở phía app khi nói chuyện với router: mở kết
/// nối, đưa client ra, đóng lại. Không chỗ nào ở đây hiểu một lệnh nghĩa là gì
/// — đó là việc của agent trên thiết bị.
///
/// [run] còn tồn tại cho hai việc agent không tự lo được: cài chính agent, và
/// chẩn đoán thiết bị chưa có nó.
class OpenWrtSession {
  OpenWrtSession._(this._client, this.device);

  final SSHClient _client;
  final DeviceProfile device;

  bool get isClosed => _client.isClosed;

  /// Client SSH mà [SshMcpTransport] chạy trên đó.
  SSHClient get client => _client;

  static Future<OpenWrtSession> connect(
    DeviceProfile device,
    String password, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final socket = await SSHSocket.connect(
      device.host,
      device.port,
      timeout: timeout,
    );
    final client = SSHClient(
      socket,
      username: device.username,
      onPasswordRequest: () => password,
      // Router trong LAN được truy cập bằng IP, không có host key biết trước.
      // Chấp nhận đánh đổi có chủ ý: đây là công cụ quản trị LAN, không phải
      // client cho máy chủ trên Internet.
      disableHostkeyVerification: true,
    );
    await client.authenticated;
    return OpenWrtSession._(client, device);
  }

  /// Chạy lệnh shell thô.
  ///
  /// Chỉ dành cho việc cài đặt ban đầu và chẩn đoán. Hoạt động bình thường đi
  /// qua agent, nơi tham số là JSON có kiểu và không bao giờ chạm shell.
  Future<CommandResult> run(String command) async {
    if (_client.isClosed) {
      throw OpenWrtException('Mất kết nối SSH tới ${device.alias}.');
    }
    final result = await _client.runWithResult(command);
    return CommandResult(
      command: command,
      stdout: utf8.decode(result.stdout, allowMalformed: true).trim(),
      stderr: utf8.decode(result.stderr, allowMalformed: true).trim(),
      exitCode: result.exitCode,
    );
  }

  Future<void> close() async {
    _client.close();
    await _client.done;
  }
}

/// Mở phiên cho [alias], tự tra mật khẩu đã lưu.
Future<OpenWrtSession> connectByAlias(DeviceStore store, String alias) async {
  final devices = await store.list();
  final resolvedAlias = resolveDeviceAlias(
    alias,
    devices.map((device) => device.alias),
  );
  final device = resolvedAlias == null
      ? null
      : devices.where((device) => device.alias == resolvedAlias).single;
  if (device == null) {
    throw OpenWrtException(
      'Không tìm thấy một thiết bị duy nhất khớp với bí danh "$alias". '
      'Hãy dùng đúng bí danh đã lưu trong màn hình Cài đặt.',
    );
  }
  final password = await store.passwordFor(device.id);
  if (password == null || password.isEmpty) {
    throw OpenWrtException('Thiết bị "$alias" chưa có mật khẩu được lưu.');
  }
  return OpenWrtSession.connect(device, password);
}
