import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'device_profile.dart';

/// Result of one remote command.
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

/// An authenticated SSH connection to one OpenWrt device.
///
/// This is all that is left on the app side of talking to a router: open the
/// connection, hand out the client, close it. Nothing here knows what a
/// command means — the agent on the device owns that.
///
/// [run] survives for the two cases the agent cannot cover itself: installing
/// the agent in the first place, and diagnosing a device where it is missing.
class OpenWrtSession {
  OpenWrtSession._(this._client, this.device);

  final SSHClient _client;
  final DeviceProfile device;

  bool get isClosed => _client.isClosed;

  /// The SSH client, which [SshAgentTransport] rides on.
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
      // Routers on a lab LAN are reached by IP with no known host key. The
      // trade-off is accepted deliberately: this is a LAN admin tool, not a
      // client for hosts on the open internet.
      disableHostkeyVerification: true,
    );
    await client.authenticated;
    return OpenWrtSession._(client, device);
  }

  /// Runs a raw shell command.
  ///
  /// Reserved for bootstrap and diagnostics. Normal operation goes through the
  /// agent, where parameters travel as typed JSON and never reach a shell.
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

/// Opens a session for [alias], resolving its stored password.
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
