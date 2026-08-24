import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

import 'agent_protocol.dart';
import 'device_profile.dart';
import 'mcp_client.dart';
import 'mcp_transport.dart';
import 'network_apply_flow.dart';
import 'openwrt_session.dart';

/// Nội dung người dùng được hỏi để duyệt.
class ConfirmRequest {
  const ConfirmRequest({
    required this.deviceAlias,
    required this.summary,
    required this.pendingChanges,
    this.warning,
  });

  final String deviceAlias;

  /// Một dòng mô tả ý định, ví dụ "Đổi địa chỉ IP LAN thành 192.168.2.1".
  final String summary;

  /// Thay đổi đã staging, mỗi field một dòng `trước → sau`. Giá trị lấy từ
  /// diff agent báo về cho kế hoạch này nên hộp thoại không lệch khỏi thứ sẽ
  /// thật sự được ghi; chỉ nhãn field là của app.
  final String pendingChanges;

  /// Chỉ đặt cho thay đổi có thể làm mất kết nối tới thiết bị.
  final String? warning;
}

typedef ConfirmCallback = Future<bool> Function(ConfirmRequest request);

/// Trạng thái dùng chung, có thể thay đổi, mà các tool mạng thao tác lên.
///
/// Giữ kết nối SSH, client agent chạy trên đó, và callback hỏi người dùng
/// duyệt thay đổi. Catalogue tool dựng một lần lúc khởi động, nhưng hai thứ
/// thì không: callback xác nhận thuộc về màn hình đang ở trên cùng, và danh
/// sách tool đáng đưa ra phụ thuộc thiết bị đang kết nối.
class ToolHost {
  /// Cố ý không phải thiết lập do model điều khiển. App chỉ bật khi tự lo được
  /// trọn vẹn apply, kết nối lại và xác nhận sức khoẻ.
  ToolHost({this.networkApplyEnabled = false});

  OpenWrtSession? _session;
  McpClient? _client;
  String? _alias;

  /// Do màn hình chat gán; mặc định là từ chối, để không lệnh ghi nào lọt qua
  /// khi không có UI nào đang lắng nghe.
  ConfirmCallback confirm = (_) async => false;

  final bool networkApplyEnabled;

  bool _networkChangeInProgress = false;
  bool get networkChangeInProgress => _networkChangeInProgress;

  McpClient? get client => _client;

  /// Hiện có phiên agent nào đang sống hay không.
  bool get isConnected => _client != null && !(_session?.isClosed ?? true);

  /// Tên các tool thiết bị đang kết nối tự khai. Rỗng khi chưa kết nối.
  ///
  /// Đây là thứ thu hẹp prompt về những tool thật sự chạy được. Cố ý dùng cùng
  /// phép kiểm tra liveness với [requireClient]: sau khi phiên SSH rớt, danh
  /// sách của thiết bị cũ không được giữ lại tool nay chỉ có thể lỗi.
  ///
  /// Chỉ tên, không bao giờ có mô tả — cùng ranh giới tin cậy với
  /// [McpServerInfo].
  Set<String> get deviceToolNames => isConnected
      ? _client!.server?.toolNames ?? const <String>{}
      : const <String>{};

  /// Bí danh thiết bị đang kết nối, dùng cho hộp thoại xác nhận.
  String get deviceAlias => _alias ?? 'thiết bị';

  String? get connectedDeviceAlias => isConnected ? _alias : null;

  /// Agent đang kết nối, hoặc lỗi chỉ cho model biết phải làm gì trước.
  McpClient requireClient() {
    if (_networkChangeInProgress) {
      throw OpenWrtException(
        'Đang đổi cấu hình mạng; chờ kết nối lại và xác nhận an toàn xong.',
      );
    }
    final client = _client;
    if (client == null || !isConnected) {
      throw OpenWrtException(
        'Chưa kết nối tới thiết bị nào. Hãy gọi connect_device trước.',
      );
    }
    return client;
  }

  Future<void> adopt(OpenWrtSession session, McpClient client) async {
    await _session?.close();
    _session = session;
    _client = client;
    _alias = session.device.alias;
  }

  Future<void> disconnect() async {
    await _session?.close();
    _session = null;
    _client = null;
    _alias = null;
  }

  /// Áp dụng bản xem trước LAN tĩnh *đã được duyệt*, kết nối lại tại địa chỉ
  /// mới, rồi chốt rollback guard trên router.
  ///
  /// Cả [planToken] lẫn health token đều không rời khỏi hàm này. LLM chỉ thấy
  /// [NetworkApplyOutcome].
  Future<NetworkApplyOutcome> applyApprovedStaticLanChange({
    required DeviceStore deviceStore,
    required String planToken,
    required String healthToken,
    required int deadlineSeconds,
    required String newHost,
  }) async {
    if (!networkApplyEnabled) {
      return const NetworkApplyOutcome(
        status: 'apply_disabled',
        message: 'Áp dụng thay đổi mạng chưa được bật trong ứng dụng.',
      );
    }
    if (_networkChangeInProgress) {
      return const NetworkApplyOutcome(
        status: 'transaction_busy',
        message: 'Một thay đổi mạng khác đang được xử lý.',
      );
    }

    final oldSession = _session;
    final oldClient = requireClient();
    if (oldSession == null || oldSession.isClosed) {
      throw OpenWrtException('Mất kết nối trước khi có thể áp dụng thay đổi.');
    }
    final originalDevice = oldSession.device;
    final password = await deviceStore.passwordFor(originalDevice.id);
    if (password == null || password.isEmpty) {
      throw OpenWrtException('Thiết bị chưa có mật khẩu SSH được lưu.');
    }

    _networkChangeInProgress = true;
    try {
      final candidate = DeviceProfile(
        id: originalDevice.id,
        alias: originalDevice.alias,
        host: newHost,
        port: originalDevice.port,
        username: originalDevice.username,
      );
      return await runApprovedNetworkApply(
        applyEnabled: networkApplyEnabled,
        approved: true,
        proto: 'static',
        planToken: planToken,
        previewHealthToken: healthToken,
        previewDeadlineSeconds: deadlineSeconds,
        apply: (arguments) async {
          try {
            return await oldClient.callTool('network_set_apply', arguments);
          } on AgentProtocolException {
            // Losing this reply is expected if applying the new LAN address
            // tears down the old SSH connection. Reconnect still uses the
            // preview-bound health token and deadline above.
            return const <String, dynamic>{};
          } on SSHSocketError {
            // dartssh2 reports a connection reset as a raw socket error.
            // At this point it means the old LAN address was replaced, so
            // proceed with reconnecting to the new address.
            return const <String, dynamic>{};
          }
        },
        reconnectAndConfirmHealth:
            ({required healthToken, required deadlineSeconds}) =>
                _reconnectAndConfirmHealth(
                  deviceStore: deviceStore,
                  originalDevice: originalDevice,
                  password: password,
                  candidate: candidate,
                  healthToken: healthToken,
                  deadlineSeconds: deadlineSeconds,
                ),
      );
    } finally {
      _networkChangeInProgress = false;
    }
  }

  Future<bool> _reconnectAndConfirmHealth({
    required DeviceStore deviceStore,
    required DeviceProfile originalDevice,
    required String password,
    required DeviceProfile candidate,
    required String healthToken,
    required int deadlineSeconds,
  }) async {
    // Địa chỉ cũ dự kiến biến mất sau khi apply. Đóng nó cũng ngăn một lệnh
    // đọc sau đó tranh chấp với luồng kết nối lại và xác nhận sức khoẻ.
    await disconnect();
    final deadline = DateTime.fromMillisecondsSinceEpoch(
      deadlineSeconds * Duration.millisecondsPerSecond,
    ).subtract(const Duration(seconds: 1));

    while (DateTime.now().isBefore(deadline)) {
      OpenWrtSession? replacement;
      try {
        replacement = await OpenWrtSession.connect(
          candidate,
          password,
          timeout: const Duration(seconds: 5),
        );
        final replacementClient = McpClient(
          SshMcpTransport(replacement.client),
        );
        final server = await replacementClient.connect();
        if (!server.toolNames.contains('network_set_health_confirm')) {
          throw OpenWrtException(
            'Agent mới không hỗ trợ xác nhận sức khỏe mạng.',
          );
        }

        // Một phiên MCP sống cộng với một lần đọc LAN chứng minh địa chỉ mới
        // đúng là router này, trước khi chốt rollback guard.
        final lan = await replacementClient.callTool('network_get', {
          'interface': 'lan',
        });
        if (lan['ipaddr']?.toString() != candidate.host) {
          throw OpenWrtException(
            'Router tại địa chỉ mới không báo đúng IP LAN dự kiến.',
          );
        }
        final confirmed = await replacementClient.callTool(
          'network_set_health_confirm',
          {'health_token': healthToken},
        );
        if (confirmed['status']?.toString() != 'confirmed') {
          throw OpenWrtException('Agent không xác nhận sức khỏe mạng.');
        }

        await deviceStore.upsert(
          id: originalDevice.id,
          alias: originalDevice.alias,
          host: candidate.host,
          port: originalDevice.port,
          username: originalDevice.username,
        );
        await adopt(replacement, replacementClient);
        replacement = null; // ToolHost now owns it.
        return true;
      } catch (_) {
        await replacement?.close();
        if (DateTime.now().add(const Duration(seconds: 1)).isBefore(deadline)) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
    return false;
  }
}
