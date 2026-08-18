import 'package:llamadart/llamadart.dart';

import '../net/agent_client.dart';
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
  _networkList(host),
  _wifiGet(host),
  _routeInfo(host),
  _trafficStats(host),
  _networkSetPreview(store, host),
];

/// The only router tools that may ever be exposed to the LLM.
///
/// Doubles as the local/remote boundary: every name in here runs on the router
/// (and therefore calls `host.requireClient()`), everything else in the
/// catalogue runs on the phone. [toolsFor] relies on that, and so does the
/// `unavailable_tools` report in `connect_device`.
const Set<String> kLlmRouterToolNames = {
  'network_get',
  'network_list',
  'wifi_get',
  'route_info',
  'traffic_stats',
  // This is the only network-changing action the model can request. Its
  // handler performs the preview and presents the native confirmation dialog.
  'network_set_preview',
};

/// Backward-compatible name used by existing capability tests.
const Set<String> kReadToolNames = kLlmRouterToolNames;

/// The tools worth putting in the prompt for the current connection state.
///
/// [catalogue] is the whole list from [buildNetworkTools]; the return value is
/// the subset whose schemas earn their tokens right now:
///
/// - **Not connected:** local tools only. A read tool here can do nothing but
///   throw "Chưa kết nối tới thiết bị nào", so its schema costs context on
///   every turn and offers the model a round it cannot win.
/// - **Connected:** local tools, plus the router tools *this* device declares.
///   A tool the firmware does not have stops being offered at all, instead of
///   being called and answered with `unsupported_tool`.
///
/// The catalogue is split before filtering, not filtered whole. `list_devices`
/// and `connect_device` run on the phone, so the router never names them —
/// handing the full catalogue to [negotiateTools] would drop the one tool the
/// model needs to connect in the first place, and there would be no way back.
///
/// Only names cross the boundary here: every description and parameter schema
/// still comes from this file. See [negotiateTools].
List<ToolDefinition> toolsFor(
  List<ToolDefinition> catalogue,
  Set<String> deviceToolNames,
) {
  final local = catalogue.where((t) => !kLlmRouterToolNames.contains(t.name));
  final remote = negotiateTools(
    catalogue.where((t) => kLlmRouterToolNames.contains(t.name)).toList(),
    deviceToolNames,
  );
  return [...local, ...remote];
}

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

/// Kết nối tới router. Tham số `device` là chỗ yếu nhất của cả file: nó là tham
/// số tự do duy nhất, lại là tham số model buộc phải điền đúng. Alias sai hiện
/// đi thẳng ra ngoài thành `{'error': ...}` trần, không `hint`, không
/// `valid_values` — xem W1 trong `docs/RA-SOAT-TOOL-SCHEMA.md`.
ToolDefinition _connectDevice(
  DeviceStore store,
  ToolHost host,
) => ToolDefinition(
  name: 'connect_device',
  description:
      'Kết nối SSH tới một router OpenWrt theo bí danh, và đặt nó làm '
      'thiết bị đang làm việc. Trước khi gọi, phải dùng list_devices và '
      'truyền đúng trường alias trong kết quả; từ “router” hoặc “thiết bị” '
      'trong câu người dùng không phải là bí danh.',
  parameters: [
    ToolParam.string(
      'device',
      description: 'Giá trị alias chính xác, lấy từ list_devices',
      required: true,
    ),
  ],
  handler: (params) async {
    final alias = params.getRequiredString('device');
    final session = await connectByAlias(store, alias);
    final client = McpClient(SshMcpTransport(session.client));

    final McpServerInfo server;
    try {
      // The device describes itself here — identity and supported tools in
      // one exec, instead of the app probing for them.
      server = await client.connect();
    } catch (_) {
      // Between connectByAlias and adopt, the session is live but unowned:
      // ToolHost does not hold it yet, so nothing would ever close it. A
      // router without the agent installed fails exactly here, and the model
      // is told to retry — so this leaked one SSH connection per attempt,
      // for the rest of the app's life.
      await session.close();
      rethrow;
    }
    await host.adopt(session, client);

    // `tools/list` is the router's capability report, not the app's
    // catalogue. Only report the intersection: a newer router may expose
    // a name this build has no schema or safe handler for, and showing it
    // as available makes the model ask for a tool it cannot invoke.
    final supported = kLlmRouterToolNames.intersection(server.toolNames);
    final missing = kLlmRouterToolNames.difference(server.toolNames);
    return {
      'connected': true,
      'device': alias,
      'agent': server.name,
      'agent_version': server.version,
      'supported_tools': supported.toList()..sort(),
      // Not what keeps the model from calling a missing tool — [toolsFor]
      // does that by not offering it. This is the *explanation* for the
      // absence, so the model can say "router này không đọc được lưu
      // lượng" instead of being silently unable to.
      if (missing.isNotEmpty) 'unavailable_tools': missing.toList()..sort(),
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

ToolDefinition _networkList(ToolHost host) => _readTool(
  host,
  name: 'network_list',
  description:
      'Liệt kê các interface mạng UCI của router. Dùng khi người dùng hỏi '
      'router có những interface nào, hoặc cần chọn interface trước khi đọc '
      'cấu hình chi tiết.',
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

/// Creates a LAN change preview and owns the entire confirmation boundary.
///
/// `network_set_apply` intentionally has no [ToolDefinition]. The model never
/// sees a plan token and can therefore never apply a network change itself.
/// After the native confirmation dialog, the app owns apply, reconnect, and
/// health confirmation end-to-end. DHCP remains preview-only because its new
/// address cannot be known reliably enough to reconnect safely.
ToolDefinition _networkSetPreview(
  DeviceStore store,
  ToolHost host,
) => ToolDefinition(
  name: 'network_set_preview',
  description:
      'Tạo bản xem trước để đổi cấu hình mạng LAN, chưa áp dụng. Chỉ gọi sau '
      'khi đã đọc network_get. Chỉ hỗ trợ static hoặc dhcp. Với static cần '
      'ipaddr và netmask; gateway có thể rỗng. Với dhcp, ipaddr, netmask và '
      'gateway phải là chuỗi rỗng. Ứng dụng hiện hộp xác nhận trước khi áp '
      'dụng IP tĩnh; DHCP chỉ hỗ trợ xem trước.',
  parameters: [
    ToolParam.enumType(
      'interface',
      values: const ['lan'],
      description: 'Luôn là LAN.',
      required: true,
    ),
    ToolParam.enumType(
      'proto',
      values: const ['static', 'dhcp'],
      description: 'Kiểu kết nối mới.',
      required: true,
    ),
    ToolParam.string('ipaddr', description: 'IP mới, hoặc rỗng với DHCP.'),
    ToolParam.string(
      'netmask',
      description: 'Netmask mới, hoặc rỗng với DHCP.',
    ),
    ToolParam.string('gateway', description: 'Gateway mới, có thể rỗng.'),
  ],
  handler: (params) async {
    final interface = params.getRequiredString('interface').trim();
    final proto = params.getRequiredString('proto').trim();
    final ipaddr = params.getString('ipaddr')?.trim() ?? '';
    final netmask = params.getString('netmask')?.trim() ?? '';
    final gateway = params.getString('gateway')?.trim() ?? '';

    _validateLanChange(
      interface: interface,
      proto: proto,
      ipaddr: ipaddr,
      netmask: netmask,
      gateway: gateway,
    );

    final client = host.requireClient();
    try {
      // This read is deliberately enforced in code, not merely requested in
      // the prompt. The preview is always made against an observed baseline.
      final current = await client.callTool('network_get', {
        'interface': interface,
      });
      final preview = await client.callTool('network_set_preview', {
        'interface': interface,
        'proto': proto,
        'ipaddr': ipaddr,
        'netmask': netmask,
        'gateway': gateway,
      });
      final planToken = preview['plan_token'];
      if (planToken is! String || planToken.isEmpty) {
        throw AgentProtocolException(
          'Preview không trả về mã xác nhận hợp lệ.',
        );
      }

      final approved = await host.confirm(
        ConfirmRequest(
          deviceAlias: host.deviceAlias,
          summary: _lanChangeSummary(proto: proto, ipaddr: ipaddr),
          pendingChanges: _formatNetworkPreview(preview),
          warning:
              'Đổi cấu hình LAN có thể làm điện thoại mất kết nối với router. '
              'Nếu xảy ra, hãy kết nối lại bằng địa chỉ IP mới.',
        ),
      );
      final safePreview = _safePreview(preview);
      if (!approved) {
        return {
          'status': 'cancelled',
          'message': 'Người dùng đã hủy, router không thay đổi.',
          'current': current,
          'preview': safePreview,
        };
      }

      if (proto == 'dhcp') {
        return {
          'status': 'preview_confirmed_not_applied',
          'message':
              'Đổi LAN sang DHCP chưa thể áp dụng tự động vì ứng dụng không '
              'biết địa chỉ mới để kết nối lại và xác nhận an toàn.',
          'current': current,
          'preview': safePreview,
        };
      }

      final outcome = await host.applyApprovedStaticLanChange(
        deviceStore: store,
        planToken: planToken,
        newHost: ipaddr,
      );
      return {
        ...outcome.toModelJson(),
        'current': current,
        'preview': safePreview,
      };
    } on AgentErrorException catch (error) {
      return explainAgentError(error, null);
    }
  },
);

void _validateLanChange({
  required String interface,
  required String proto,
  required String ipaddr,
  required String netmask,
  required String gateway,
}) {
  if (interface != 'lan') {
    throw UciValidationException('Chỉ hỗ trợ thay đổi cấu hình LAN.');
  }
  if (proto == 'dhcp') {
    if (ipaddr.isNotEmpty || netmask.isNotEmpty || gateway.isNotEmpty) {
      throw UciValidationException(
        'Dùng DHCP thì không nhập IP, netmask hoặc gateway.',
      );
    }
    return;
  }
  if (proto != 'static') {
    throw UciValidationException(
      'Kiểu kết nối chỉ có thể là static hoặc dhcp.',
    );
  }
  if (ipaddr.isEmpty || netmask.isEmpty) {
    throw UciValidationException('IP và netmask là bắt buộc khi dùng IP tĩnh.');
  }
  validateIpv4(ipaddr, 'IP LAN');
  validateNetmask(netmask);
  if (gateway.isNotEmpty) validateIpv4(gateway, 'Gateway');
}

String _lanChangeSummary({required String proto, required String ipaddr}) =>
    proto == 'dhcp'
    ? 'Chuyển mạng LAN sang tự động nhận địa chỉ IP.'
    : 'Đổi địa chỉ IP LAN thành $ipaddr.';

String _formatNetworkPreview(Map<String, dynamic> preview) {
  final rawDiff = preview['diff'];
  if (rawDiff is! Map) return 'Router đã tạo bản xem trước thay đổi LAN.';

  const labels = {
    'proto': 'Kiểu kết nối',
    'ipaddr': 'Địa chỉ IP',
    'netmask': 'Netmask',
    'gateway': 'Gateway',
  };
  final lines = <String>[];
  for (final entry in labels.entries) {
    final change = rawDiff[entry.key];
    if (change is! Map) continue;
    final before = change['before']?.toString() ?? 'trống';
    final after = change['after']?.toString() ?? 'trống';
    if (before != after) lines.add('${entry.value}: $before → $after');
  }
  return lines.isEmpty ? 'Không có thay đổi cấu hình LAN.' : lines.join('\n');
}

Map<String, dynamic> _safePreview(Map<String, dynamic> preview) => {
  if (preview['request'] is Map) 'request': preview['request'],
  if (preview['diff'] is Map) 'diff': preview['diff'],
};

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
        return explainAgentError(error, choices);
      }
    },
  );
}

/// Turns an agent error into something the model can act on.
///
/// [choices] is repeated back on failure because the model has no tool that
/// lists valid names, and by the time an error arrives the tool description may
/// have fallen out of its context window.
///
/// Public so the contract it defines can be tested. Nothing else calls it: this
/// is the only shape a failed read reaches the model in, and the hint inside it
/// is the only thing that tells a 1.5B model whether to retry or to stop.
Map<String, dynamic> explainAgentError(
  AgentErrorException error,
  List<String>? choices,
) {
  // Withheld when the tool itself is absent, even though the values are still
  // valid names. A list of alternatives sitting next to "đừng gọi lại" reads as
  // an invitation to try the next one, and with a small model the data wins over
  // the prose. Nothing in valid_values can fix a tool the firmware lacks.
  final worthRetrying = !isUnsupportedTool(error.code);

  return {
    'error': error.code,
    'message': error.message,
    'hint': hintForAgentError(error.code, choices),
    if (worthRetrying && choices != null) 'valid_values': choices,
  };
}

/// The advice attached to [code]: retry, or stop and say why.
String hintForAgentError(String code, List<String>? choices) {
  if (isUnsupportedTool(code)) {
    // Used to fall through to the "wrong parameter" branch below, which sent the
    // model hunting for another section name on a tool that does not exist on
    // this device — the exact wasted turn the rest of this file is built to
    // prevent.
    return 'Thiết bị này không có chức năng đó, và lượt sau cũng vậy. Đừng gọi '
        'lại công cụ này và đừng thử tên khác; hãy nói với người dùng là router '
        'không hỗ trợ việc này.';
  }

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
