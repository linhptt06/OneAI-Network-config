import 'package:llamadart/llamadart.dart';

import 'agent_protocol.dart';
import 'agent_transport.dart';

/// Drives the on-router agent: capability discovery, then staged writes.
///
/// Holds no device knowledge of its own. Which UCI keys a tool touches, and
/// how a given firmware applies them, is the agent's business; this class only
/// moves typed requests and results across the boundary.
class AgentClient {
  AgentClient(this._transport);

  final AgentTransport _transport;

  AgentCapabilities? _capabilities;
  AgentCapabilities? get capabilities => _capabilities;

  /// Asks the device what it supports and caches the answer.
  ///
  /// Throws [AgentIncompatibleException] on a contract mismatch rather than
  /// proceeding, because a partially understood protocol is more dangerous
  /// than no protocol when the operations change network configuration.
  Future<AgentCapabilities> discover() async {
    final result = await _transport.send(buildRequest(AgentMethod.list));
    final capabilities = AgentCapabilities.fromJson(result);
    if (!capabilities.isCompatible) {
      throw AgentIncompatibleException(
        deviceVersion: capabilities.contractVersion,
        appVersion: kAgentContractVersion,
      );
    }
    _capabilities = capabilities;
    return capabilities;
  }

  /// Runs a read-only tool and returns its result verbatim.
  ///
  /// Reads need no staging: nothing changes, so there is nothing to approve or
  /// roll back. The result is passed straight to the model, which is why the
  /// shape is left to the agent rather than typed here.
  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, dynamic> args = const {},
  ]) async {
    _requireSupported(tool);
    return _transport.send(
      buildRequest(AgentMethod.call, tool: tool, args: args),
    );
  }

  /// Applies [args] to the staging area without committing.
  Future<StagedChange> stage(String tool, Map<String, dynamic> args) async {
    _requireSupported(tool);
    final result = await _transport.send(
      buildRequest(AgentMethod.stage, tool: tool, args: args),
    );
    return StagedChange.fromJson(result);
  }

  /// Commits a staged change and returns the agent's verification evidence.
  Future<CommitOutcome> commit(StagedChange change) async {
    final result = await _transport.send(
      buildRequest(AgentMethod.commit, token: change.token),
    );
    return CommitOutcome.fromJson(result);
  }

  /// Discards a staged change. Safe to call twice.
  Future<void> revert(StagedChange change) async {
    await _transport.send(
      buildRequest(AgentMethod.revert, token: change.token),
    );
  }

  void _requireSupported(String tool) {
    final capabilities = _capabilities;
    if (capabilities == null) {
      throw StateError('Phải gọi discover() trước khi dùng tool.');
    }
    if (!capabilities.toolNames.contains(tool)) {
      throw AgentErrorException(
        'unsupported_tool',
        'Thiết bị này không hỗ trợ "$tool".',
      );
    }
  }
}

/// The device speaks a protocol revision this build cannot drive.
class AgentIncompatibleException implements Exception {
  AgentIncompatibleException({
    required this.deviceVersion,
    required this.appVersion,
  });

  final int deviceVersion;
  final int appVersion;

  @override
  String toString() =>
      'Agent trên thiết bị dùng hợp đồng phiên bản $deviceVersion, '
      'ứng dụng cần $appVersion. Hãy cập nhật agent hoặc ứng dụng.';
}

/// Narrows [appTools] to those the device reports supporting.
///
/// This is where the trust boundary is enforced. The device contributes only
/// tool *names*, used as a filter; every description and parameter schema the
/// model sees comes from [appTools]. A compromised router can therefore hide
/// tools or claim ones it cannot perform — both merely inconvenient — but it
/// cannot place a single word into the model's context.
///
/// Names the app does not define are ignored rather than trusted.
///
/// Takes a bare name set so both wire protocols can use it: the MCP server
/// reports names through `tools/list`, the staged-write agent through its
/// `list` reply.
List<ToolDefinition> negotiateTools(
  List<ToolDefinition> appTools,
  Set<String> deviceToolNames,
) => appTools.where((tool) => deviceToolNames.contains(tool.name)).toList();

/// Names the device offered that this build has no definition for.
///
/// Not an error: it usually means the agent is newer than the app. Surfaced so
/// the mismatch is visible in diagnostics instead of silently narrowing what
/// the assistant can do.
Set<String> unknownToolNames(
  List<ToolDefinition> appTools,
  Set<String> deviceToolNames,
) {
  final known = appTools.map((t) => t.name).toSet();
  return deviceToolNames.difference(known);
}
