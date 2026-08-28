import 'package:llamadart/llamadart.dart';

import '../net/agent_protocol.dart';
import '../net/device_profile.dart';
import '../net/mcp_client.dart';
import '../net/mcp_transport.dart';
import '../net/openwrt_session.dart';
import '../net/tool_host.dart';
import '../net/validation.dart';
import 'tool_catalogue.dart';

/// Các tool model được phép gọi lên router OpenWrt.
///
/// File này sở hữu *giao diện* tool: tên, mô tả, schema tham số mà model nhìn
/// thấy, cộng phần validate chặn giá trị sai trước khi tốn một vòng đi router.
/// Nó không biết gì về UCI.
///
/// Tên tool trùng khớp với agent, không phải chuyện thẩm mỹ: thiết bị khai tên,
/// app đối chiếu theo tên, đặt tên riêng thì không khớp được gì cả.
///
/// Tất cả đều là tool đọc, trừ `network_set_preview` — đường ghi duy nhất, và
/// nó cũng chỉ staging thay đổi để hộp thoại xác nhận duyệt.
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

/// Những tool router duy nhất được phép lộ ra cho LLM.
///
/// Cũng chính là ranh giới cục bộ/từ xa: mọi tên trong đây chạy trên router
/// (nên đều gọi `host.requireClient()`), phần còn lại chạy trên điện thoại.
/// [toolsFor] và báo cáo `unavailable_tools` đều dựa vào ranh giới này.
const Set<String> kLlmRouterToolNames = {
  'network_get',
  'network_list',
  'wifi_get',
  'route_info',
  'traffic_stats',
  // Thao tác đổi mạng duy nhất model xin được. Handler của nó tạo bản xem
  // trước rồi mở hộp thoại xác nhận của hệ thống.
  'network_set_preview',
};

/// Tên cũ của [kLlmRouterToolNames], giữ lại cho các test capability.
///
/// Tên này có trước `network_set_preview`; tập hợp không còn chỉ-đọc nữa.
const Set<String> kReadToolNames = kLlmRouterToolNames;

/// Những tool đáng đưa vào prompt ứng với trạng thái kết nối hiện tại.
///
/// - **Chưa kết nối:** chỉ tool cục bộ. Tool đọc lúc này chỉ ném được "Chưa
///   kết nối tới thiết bị nào", nên schema của nó tốn context vô ích.
/// - **Đã kết nối:** thêm các tool router mà *thiết bị này* khai báo. Tool
///   firmware không có thì không đưa ra, thay vì bị gọi rồi trả
///   `unsupported_tool`.
///
/// Catalogue được tách trước khi lọc chứ không lọc cả cụm: `list_devices` và
/// `connect_device` chạy trên điện thoại nên router không bao giờ khai tên
/// chúng — lọc cả cụm sẽ mất luôn tool để kết nối, và không có đường quay lại.
///
/// Chỉ có tên đi qua ranh giới này; mọi mô tả và schema vẫn từ file này.
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

// Giá trị mặc định để model luôn có cái hợp lệ mà gửi khi người dùng hỏi
// chung chung. Model không tự tìm ra được: agent không có tool liệt kê section,
// nên đoán sai là không có đường sửa.
const String kDefaultNetworkInterface = 'lan';

/// Section Wi-Fi AP đang bật trên router OpenWrt đang dùng. Tên này được lấy
/// từ `uci show wireless`: `ra0` là wifi-iface 5 GHz có SSID `oneai`.
const String kDefaultWifiSection = 'ra0';
const String kDefaultTrafficInterface = 'br-lan';

/// Các section wireless đưa cho model.
///
/// Khai báo dạng enum chứ không kể trong mô tả: mô tả chỉ là lời khuyên mà
/// model nhỏ bỏ qua — nó từng bịa ra `wlan0` dù có sẵn danh sách này trước mặt
/// — còn enum thành ràng buộc grammar GBNF mà sampler không thoát ra được.
///
/// Luôn đọc AP đang bật thay vì radio hoặc interface client/đang tắt.
const List<String> kWifiSections = [kDefaultWifiSection];

const List<String> kNetworkInterfaces = ['lan', 'wan', 'loopback'];

// ---------------------------------------------------------------------------
// Tool cục bộ — chạy trên điện thoại, không phải trên router
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

/// Kết nối tới router. `device` là chỗ yếu nhất của cả file: tham số tự do duy
/// nhất, lại là thứ model buộc phải điền đúng. Alias sai hiện đi thẳng ra
/// ngoài thành `{'error': ...}` trần, không `hint`, không `valid_values`.
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
      // Thiết bị tự khai ở đây: danh tính và danh sách tool trong một lần
      // exec, thay vì app phải dò từng thứ.
      server = await client.connect();
    } catch (_) {
      // Giữa connectByAlias và adopt, phiên đang sống nhưng vô chủ: ToolHost
      // chưa giữ nên không ai đóng nó. Router chưa cài agent hỏng đúng ở đây
      // và model được bảo thử lại — mỗi lần thử là rò một kết nối SSH.
      await session.close();
      rethrow;
    }
    await host.adopt(session, client);

    // `tools/list` là báo cáo capability của router, không phải catalogue của
    // app. Chỉ lấy phần giao: router mới có thể khai tên mà bản build này chưa
    // có schema hay handler an toàn.
    final supported = kLlmRouterToolNames.intersection(server.toolNames);
    final missing = kLlmRouterToolNames.difference(server.toolNames);
    return {
      'connected': true,
      'device': alias,
      'agent': server.name,
      'agent_version': server.version,
      'supported_tools': supported.toList()..sort(),
      // Không phải thứ chặn model gọi tool thiếu — [toolsFor] làm việc đó
      // bằng cách không đưa ra. Đây là *lời giải thích* cho sự vắng mặt, để
      // model nói được "router này không đọc được lưu lượng".
      if (missing.isNotEmpty) 'unavailable_tools': missing.toList()..sort(),
    };
  },
);

// ---------------------------------------------------------------------------
// Tool đọc — chuyển tiếp xuống agent
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
      'Liệt kê các interface mạng của router. Dùng khi người dùng hỏi '
      'router có những interface nào, hoặc cần chọn interface trước khi đọc '
      'cấu hình chi tiết.',
);

ToolDefinition _wifiGet(ToolHost host) => _readTool(
  host,
  name: 'wifi_get',
  description:
      'Đọc cấu hình WiFi của router: tên mạng (SSID), kiểu mã hoá, chế độ, '
      'kênh. KHÔNG đọc được mật khẩu WiFi.',
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
  // Cố ý để tự do: tên cổng của hệ điều hành phụ thuộc cấu hình mạng, danh
  // sách cứng sẽ chặn nhầm tên hợp lệ trên board khác.
  defaultValue: kDefaultTrafficInterface,
  validate: validateInterfaceName,
);

/// Tạo bản xem trước đổi LAN và giữ toàn bộ ranh giới xác nhận.
///
/// `network_set_apply` cố ý không có [ToolDefinition]: model không bao giờ
/// thấy plan token nên không tự áp dụng thay đổi được. Sau khi người dùng bấm
/// đồng ý, app tự lo apply, kết nối lại và xác nhận sức khoẻ. DHCP chỉ dừng ở
/// xem trước vì không biết chắc địa chỉ mới để kết nối lại an toàn.
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
      // Bước đọc này ép trong code chứ không chỉ nhờ prompt, để bản xem trước
      // luôn dựa trên hiện trạng quan sát được.
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
      final healthToken = preview['health_token'];
      final deadline = preview['deadline'];
      if (planToken is! String ||
          planToken.isEmpty ||
          healthToken is! String ||
          healthToken.length != 64 ||
          deadline is! num) {
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
        healthToken: healthToken,
        deadlineSeconds: deadline.toInt(),
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

/// Tool chỉ đọc: không staging, không xác nhận, không định dạng kết quả riêng
/// — phản hồi của agent đi thẳng tới model.
///
/// Nhiều nhất một tham số, vì agent chỉ nhận thế: schema đặt
/// `additionalProperties: false` và kiểm lại lần nữa. Thừa field là bị từ chối
/// thẳng, nên payload được dựng lại ở đây thay vì bê nguyên model viết.
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
        // Vẫn chạy dù grammar đã ràng buộc giá trị: grammar ràng model chứ
        // không ràng lần sửa file này sau này, mà đây là đường ra thiết bị.
        validate?.call(value);
        arguments[argument] = value;
      }

      try {
        return await host.requireClient().callTool(name, arguments);
      } on AgentErrorException catch (error) {
        // Trả về dạng dữ liệu chứ không ném: ném thì model vẫn nhận được lỗi
        // nhưng mất hint — thứ ngăn model nhỏ thử lại một lời gọi vô vọng.
        return explainAgentError(error, choices);
      }
    },
  );
}

/// Biến lỗi từ agent thành thứ model hành động được.
///
/// [choices] được nhắc lại khi lỗi vì model không có tool nào liệt kê tên hợp
/// lệ, và lúc lỗi về thì mô tả tool có thể đã rơi khỏi context.
///
/// Để public cho test kiểm chứng hợp đồng này. Đây là hình dạng duy nhất một
/// lỗi đọc đến được model, và hint bên trong là thứ bảo nó thử lại hay dừng.
Map<String, dynamic> explainAgentError(
  AgentErrorException error,
  List<String>? choices,
) {
  // Giấu đi khi chính tool không tồn tại, dù các giá trị vẫn là tên hợp lệ.
  // Một danh sách gợi ý nằm cạnh "đừng gọi lại" đọc như lời mời thử tiếp, và
  // với model nhỏ thì dữ liệu thắng lời văn.
  final worthRetrying = !isUnsupportedTool(error.code);

  return {
    'error': error.code,
    'message': error.message,
    'hint': hintForAgentError(error.code, choices),
    if (worthRetrying && choices != null) 'valid_values': choices,
  };
}

/// Lời khuyên kèm theo [code]: thử lại, hay dừng và nói rõ lý do.
String hintForAgentError(String code, List<String>? choices) {
  if (isUnsupportedTool(code)) {
    // Trước đây rơi xuống nhánh "sai tham số" bên dưới, khiến model đi tìm
    // tên section khác cho một tool không tồn tại trên thiết bị.
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
    // Router gộp mọi lỗi tool vào đúng một mã này nên không loại trừ được
    // cách hiểu nào. Nói thẳng là không rõ còn hơn đoán sai.
    return 'Router không nói rõ nguyên nhân. Có thể tên không tồn tại trên '
        'thiết bị này, cũng có thể router đang trục trặc. Hãy $retry; vẫn lỗi '
        'thì báo người dùng, đừng lặp thêm.';
  }

  return 'Tham số không đúng. Hãy $retry, rồi báo người dùng.';
}
