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
/// that asks the user to approve a change. The tool *catalogue* is built once at
/// startup, but two things about a tool cannot be: the confirmation callback
/// belongs to whichever screen is on top, and which tools are worth offering
/// depends on what is connected right now — see [deviceToolNames].
class ToolHost {
  OpenWrtSession? _session;
  McpClient? _client;
  String? _alias;

  /// Set by the chat screen; defaults to refusing, so a write can never slip
  /// through when no UI is listening.
  ConfirmCallback confirm = (_) async => false;

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
  Set<String> get deviceToolNames =>
      isConnected
      ? _client!.server?.toolNames ?? const <String>{}
      : const <String>{};

  /// Alias of the connected device, for confirmation dialogs.
  String get deviceAlias => _alias ?? 'thiết bị';

  /// The connected agent, or an error telling the model what to do first.
  McpClient requireClient() {
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
}
