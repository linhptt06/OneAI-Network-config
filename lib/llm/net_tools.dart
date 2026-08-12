import 'package:llamadart/llamadart.dart';

import '../net/agent_protocol.dart';
import '../net/device_profile.dart';
import '../net/mcp_client.dart';
import '../net/mcp_transport.dart';
import '../net/openwrt_session.dart';
import '../net/tool_host.dart';
import '../net/validation.dart';

/// Tools that let the model read OpenWrt configuration.
///
/// This file owns the tool *interface*: the names, descriptions and parameter
/// schemas the model sees, plus the validation that rejects a bad value before
/// it costs a round trip. It owns nothing about UCI.
///
/// Tool names match the agent's exactly. They are not a stylistic choice: the
/// device advertises names, the app matches on them, and a private naming
/// scheme would mean nothing lines up.
///
/// Only read tools exist here. The agent has no mutating tool yet, and a tool
/// that always fails is worse than a missing one — a 1.5B model derails for the
/// rest of the turn.
List<ToolDefinition> buildNetworkTools(DeviceStore store, ToolHost host) => [
  _listDevices(store),
  _connectDevice(store, host),
  _networkGet(host),
  _wifiGet(host),
  _routeInfo(host),
  _trafficStats(host),
];

/// The read tools this build knows how to drive, for reporting what a given
/// device is missing.
const Set<String> kReadToolNames = {
  'network_get',
  'wifi_get',
  'route_info',
  'traffic_stats',
};

// Defaults, so the model has something valid to send when the user asks a
// general question. The model cannot discover these: the agent exposes no tool
// that lists sections, so a wrong guess has no path back to a right one.
const String kDefaultNetworkInterface = 'lan';

/// Read off the target board (MediaTek MT7993). Stock OpenWrt would call this
/// `default_radio0`; vendor firmware does not.
const String kDefaultWifiSection = 'ra0';
const String kDefaultTrafficInterface = 'br-lan';

/// Wireless sections offered to the model, read off the target board.
///
/// Declared as an enum parameter rather than listed in prose. A description is
/// advice a 1.5B model ignores — it invented `wlan0` with these very names in
/// front of it — while an enum becomes a GBNF grammar constraint the sampler
/// cannot leave. Same mechanism as the value lists in `validation.dart`.
///
/// `apcli0`/`apclix0` are left out on purpose: they are uplinks to someone
/// else's network, and reporting one as "your WiFi" would be a confident lie.
/// `apmld1` is left out because `wifi_get` rejects its type outright.
const List<String> kWifiSections = [
  'ra0',
  'ra1',
  'ra2',
  'rax0',
  'rax1',
  'MT7993_1_1',
  'MT7993_1_2',
];

/// Network sections offered to the model. `wan6` is the IPv6 half of the WAN.
const List<String> kNetworkInterfaces = ['lan', 'wan', 'wan6'];

// ---------------------------------------------------------------------------
// Local tools — these run on the phone, not on the router
// ---------------------------------------------------------------------------

ToolDefinition _listDevices(DeviceStore store) => ToolDefinition(
  name: 'list_devices',
  description:
      'Liệt kê các thiết bị OpenWrt (router) đã được lưu trong ứng dụng. '
      'Dùng khi người dùng hỏi có những router nào, hoặc khi cần biết bí '
      'danh thiết bị trước khi kết nối.',
  parameters: [],
  handler: (params) async {
    final devices = await store.list();
    return {
      'count': devices.length,
      'devices': devices.map((d) => d.toModelJson()).toList(),
    };
  },
);

ToolDefinition _connectDevice(DeviceStore store, ToolHost host) =>
    ToolDefinition(
      name: 'connect_device',
      description:
          'Kết nối SSH tới một router OpenWrt theo bí danh, và đặt nó làm '
          'thiết bị đang làm việc. Phải gọi tool này trước mọi thao tác đọc '
          'khác.',
      parameters: [
        ToolParam.string(
          'device',
          description: 'Bí danh thiết bị, lấy từ list_devices',
          required: true,
        ),
      ],
      handler: (params) async {
        final alias = params.getRequiredString('device');
        final session = await connectByAlias(store, alias);
        final client = McpClient(SshMcpTransport(session.client));

        // The device describes itself here — identity and supported tools in
        // one exec, instead of the app probing for them.
        final server = await client.connect();
        await host.adopt(session, client);

        final missing = kReadToolNames.difference(server.toolNames);
        return {
          'connected': true,
          'device': alias,
          'agent': server.name,
          'agent_version': server.version,
          'supported_tools': server.toolNames.toList()..sort(),
          // Named so the model does not spend a round trip discovering that a
          // tool it can see is unavailable on this particular router.
          if (missing.isNotEmpty)
            'unavailable_tools': missing.toList()..sort(),
        };
      },
    );

// ---------------------------------------------------------------------------
// Read tools — forwarded to the agent
// ---------------------------------------------------------------------------

ToolDefinition _networkGet(ToolHost host) => _readTool(
  host,
  name: 'network_get',
  description:
      'Đọc cấu hình một interface mạng của router: kiểu kết nối (proto), địa '
      'chỉ IP, netmask, gateway, thiết bị. Dùng khi người dùng hỏi về IP của '
      'router, mạng LAN hoặc kết nối WAN.',
  argument: 'interface',
  argumentDescription:
      'Interface cần đọc. Bỏ trống thì đọc $kDefaultNetworkInterface.',
  choices: kNetworkInterfaces,
  defaultValue: kDefaultNetworkInterface,
  validate: (value) => validateUciSectionName(value, 'Tên interface'),
);

ToolDefinition _wifiGet(ToolHost host) => _readTool(
  host,
  name: 'wifi_get',
  description:
      'Đọc cấu hình WiFi của router: tên mạng (SSID), kiểu mã hoá, chế độ, '
      'kênh. KHÔNG đọc được mật khẩu WiFi. ra0/ra1/ra2 là mạng 2.4 GHz, '
      'rax0/rax1 là băng cao, MT7993_1_1 và MT7993_1_2 là radio (kênh, '
      'băng tần).',
  argument: 'section',
  argumentDescription:
      'Section wireless cần đọc. Bỏ trống thì đọc $kDefaultWifiSection.',
  choices: kWifiSections,
  defaultValue: kDefaultWifiSection,
  validate: (value) => validateUciSectionName(value, 'Tên section wireless'),
);

ToolDefinition _routeInfo(ToolHost host) => _readTool(
  host,
  name: 'route_info',
  description:
      'Đọc trạng thái các interface đang hoạt động và bảng định tuyến của '
      'router. Dùng khi người dùng hỏi router đang ra Internet bằng đường nào, '
      'gateway nào đang dùng, interface nào đang bật.',
);

ToolDefinition _trafficStats(ToolHost host) => _readTool(
  host,
  name: 'traffic_stats',
  description:
      'Đọc bộ đếm lưu lượng của một cổng mạng: TỔNG số byte và số gói đã '
      'nhận/gửi cộng dồn từ lúc router khởi động. ĐÂY KHÔNG PHẢI tốc độ, '
      'không phải byte mỗi giây. Tên cổng ví dụ: br-lan, eth0, ra0.',
  argument: 'interface',
  argumentDescription:
      'Tên cổng mạng của hệ điều hành. Bỏ trống thì đọc $kDefaultTrafficInterface.',
  // Free-form on purpose: OS device names follow the network configuration,
  // so a fixed list would reject names that are perfectly valid on another
  // board — unlike the UCI section names, which this build does know.
  defaultValue: kDefaultTrafficInterface,
  validate: validateInterfaceName,
);

/// A tool that only reads. No staging, no confirmation, no result shape of its
/// own — the agent's reply goes straight to the model.
///
/// At most one parameter, because that is all the agent accepts: its schema
/// sets `additionalProperties: false` and it re-checks that the argument object
/// holds nothing but the declared field. Anything extra is rejected outright,
/// so the payload is rebuilt here rather than forwarded as the model wrote it.
ToolDefinition _readTool(
  ToolHost host, {
  required String name,
  required String description,
  String? argument,
  String? argumentDescription,
  List<String>? choices,
  String? defaultValue,
  void Function(String value)? validate,
}) {
  final ToolParam? parameter;
  if (argument == null) {
    parameter = null;
  } else if (choices != null) {
    parameter = ToolParam.enumType(
      argument,
      values: choices,
      description: argumentDescription!,
    );
  } else {
    parameter = ToolParam.string(argument, description: argumentDescription!);
  }

  return ToolDefinition(
    name: name,
    description: description,
    parameters: [?parameter],
    handler: (params) async {
      final arguments = <String, dynamic>{};
      if (argument != null) {
        final written = params.getString(argument)?.trim();
        final value = (written == null || written.isEmpty)
            ? defaultValue!
            : written;
        // Runs even when the grammar already constrained the value: the
        // grammar binds the model, not a future edit to this file, and this is
        // the path to a network device.
        validate?.call(value);
        arguments[argument] = value;
      }

      try {
        return await host.requireClient().callTool(name, arguments);
      } on AgentErrorException catch (error) {
        // Returned as data rather than thrown. The turn loop would also hand a
        // thrown error to the model, but without the hint — and the hint is
        // what stops a small model from retrying a call that cannot succeed.
        return _explainFailure(error, choices);
      }
    },
  );
}

/// Turns an agent error into something the model can act on.
///
/// [choices] is repeated back on failure because the model has no tool that
/// lists valid names, and by the time an error arrives the tool description may
/// have fallen out of its context window.
Map<String, dynamic> _explainFailure(
  AgentErrorException error,
  List<String>? choices,
) => {
  'error': error.code,
  'message': error.message,
  'hint': _hintFor(error.code, choices),
  'valid_values': ?choices,
};

String _hintFor(String code, List<String>? choices) {
  if (isRouterFault(code)) {
    return 'Đây là sự cố phía router, không phải do tham số sai. Đừng gọi lại '
        'công cụ này; hãy báo người dùng.';
  }

  final retry = choices == null
      ? 'thử lại nhiều nhất MỘT lần với tên khác'
      : 'thử lại nhiều nhất MỘT lần với một tên khác trong valid_values';

  if (isAmbiguousFailure(code)) {
    // The router collapses every tool error into this one code, so neither
    // reading can be ruled out. Saying so is more useful than picking wrong.
    return 'Router không nói rõ nguyên nhân. Có thể tên không tồn tại trên '
        'thiết bị này, cũng có thể router đang trục trặc. Hãy $retry; vẫn lỗi '
        'thì báo người dùng, đừng lặp thêm.';
  }

  return 'Tham số không đúng. Hãy $retry, rồi báo người dùng.';
}
