import 'dart:async';

import 'device_profile.dart';
import 'mcp_client.dart';
import 'mcp_transport.dart';
import 'network_apply_flow.dart';
import 'openwrt_session.dart';

/// What the user is being asked to approve.
class ConfirmRequest {
  const ConfirmRequest({
    required this.deviceAlias,
    required this.summary,
    required this.pendingChanges,
    this.warning,
  });

  final String deviceAlias;

  /// One line describing the intent, e.g. "Đổi tên WiFi thành NhaToi_5G".
  final String summary;

  /// Verbatim diff reported by the agent — the device's own account of what is
  /// staged. Shown instead of a reconstructed command string so the dialog
  /// cannot drift from what will actually be committed.
  final String pendingChanges;

  /// Set for changes that can cut off access to the device.
  final String? warning;
}

typedef ConfirmCallback = Future<bool> Function(ConfirmRequest request);

/// Shared, mutable state the network tools operate on.
///
/// Holds the SSH connection, the agent client riding on it, and the callback
/// that asks the user to approve a change. The tool *catalogue* is built once at
/// startup, but two things about a tool cannot be: the confirmation callback
/// belongs to whichever screen is on top, and which tools are worth offering
/// depends on what is connected right now — see [deviceToolNames].
class ToolHost {
  /// This is deliberately not a model-controlled setting. The app turns it on
  /// only after it owns apply, reconnect, and health confirmation end to end.
  ToolHost({this.networkApplyEnabled = false});

  OpenWrtSession? _session;
  McpClient? _client;
  String? _alias;

  /// Set by the chat screen; defaults to refusing, so a write can never slip
  /// through when no UI is listening.
  ConfirmCallback confirm = (_) async => false;

  final bool networkApplyEnabled;

  bool _networkChangeInProgress = false;
  bool get networkChangeInProgress => _networkChangeInProgress;

  McpClient? get client => _client;

  /// Whether a live agent session exists right now.
  bool get isConnected => _client != null && !(_session?.isClosed ?? true);

  /// Tool names the connected device declared for itself. Empty when nothing is
  /// connected.
  ///
  /// This is what narrows the prompt to the tools that can actually run
  /// (`toolsFor` in `net_tools.dart`). It uses the same liveness check as
  /// [requireClient] on purpose: after the SSH session drops, the last device's
  /// list must not keep read tools in the prompt that can now only fail.
  ///
  /// Names only — never descriptions. Same trust boundary as [McpServerInfo].
  Set<String> get deviceToolNames => isConnected
      ? _client!.server?.toolNames ?? const <String>{}
      : const <String>{};

  /// Alias of the connected device, for confirmation dialogs.
  String get deviceAlias => _alias ?? 'thiết bị';

  String? get connectedDeviceAlias => isConnected ? _alias : null;

  /// The connected agent, or an error telling the model what to do first.
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

  /// Applies a *previously approved* static LAN preview, reconnects to the new
  /// address, and finalises the router-side rollback guard.
  ///
  /// Neither [planToken] nor the health token returned by the agent ever leave
  /// this method. In particular, the LLM sees only [NetworkApplyOutcome].
  Future<NetworkApplyOutcome> applyApprovedStaticLanChange({
    required DeviceStore deviceStore,
    required String planToken,
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
        apply: (arguments) =>
            oldClient.callTool('network_set_apply', arguments),
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
    // The old address is expected to disappear after apply. Closing it also
    // prevents a later read from racing the reconnect + health-confirm flow.
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

        // A live MCP session plus a read of LAN proves the new address is
        // serving this router before the rollback guard is finalised.
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
