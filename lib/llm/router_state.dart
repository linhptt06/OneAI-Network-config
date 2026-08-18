import '../net/device_profile.dart';
import '../net/tool_host.dart';
import 'net_tools.dart';

/// Produces the small, non-secret router context replayed on every turn.
///
/// It deliberately contains aliases and capability names only: never hosts,
/// usernames, passwords, SSH credentials, confirmation tokens or tool output.
Future<Map<String, Object?>> buildRouterState({
  required DeviceStore deviceStore,
  required ToolHost toolHost,
}) async {
  final aliases = (await deviceStore.list())
      .map((device) => device.alias)
      .toList(growable: false);
  return routerStateFor(
    aliases: aliases,
    connectedDeviceAlias: toolHost.connectedDeviceAlias,
    deviceToolNames: toolHost.deviceToolNames,
    networkApplyEnabled: toolHost.networkApplyEnabled,
  );
}

/// Pure form used by tests; callers pass aliases only, never device profiles.
Map<String, Object?> routerStateFor({
  required List<String> aliases,
  required String? connectedDeviceAlias,
  required Set<String> deviceToolNames,
  required bool networkApplyEnabled,
}) {
  final available = deviceToolNames.intersection(kLlmRouterToolNames).toList()
    ..sort();

  return {
    'saved_device_aliases': aliases,
    'connected_device_alias': connectedDeviceAlias,
    'available_router_tools': available,
    'network_apply_enabled': networkApplyEnabled,
  };
}
