import '../net/device_profile.dart';
import '../net/tool_host.dart';
import 'net_tools.dart';

/// Dựng phần ngữ cảnh router nhỏ, không chứa bí mật, phát lại ở mọi lượt.
///
/// Cố ý chỉ có bí danh và tên capability: không có host, tài khoản, mật khẩu,
/// token xác nhận hay kết quả tool.
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

/// Dạng thuần cho test; bên gọi chỉ truyền bí danh, không truyền hồ sơ.
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
