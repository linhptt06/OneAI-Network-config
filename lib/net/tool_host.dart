import 'mcp_client.dart';
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
/// that asks the user to approve a change. Tool definitions are built once at
/// startup, but the confirmation callback belongs to whichever screen is on
/// top, so it lives here rather than being captured at build time.
class ToolHost {
  OpenWrtSession? _session;
  McpClient? _client;
  String? _alias;

  /// Set by the chat screen; defaults to refusing, so a write can never slip
  /// through when no UI is listening.
  ConfirmCallback confirm = (_) async => false;

  McpClient? get client => _client;

  /// Alias of the connected device, for confirmation dialogs.
  String get deviceAlias => _alias ?? 'thiết bị';

  /// The connected agent, or an error telling the model what to do first.
  McpClient requireClient() {
    final client = _client;
    if (client == null || (_session?.isClosed ?? true)) {
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
}
