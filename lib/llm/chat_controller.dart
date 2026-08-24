import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../data/chat_database.dart';
import '../data/chat_models.dart';
import '../net/device_profile.dart';
import '../net/tool_host.dart';
import 'llm_service.dart';
import 'net_tools.dart';
import 'router_state.dart';

/// Quy tắc "làm ngay, đừng thông báo" có vì model nhỏ hay trả lời "Đang kiểm
/// tra..." rồi dừng thay vì gọi tool. Cấm thẳng hành vi đó mới dập được.
const String kSystemPrompt =
    'Bạn là trợ lý quản trị router OpenWrt. Trả lời tiếng Việt tự nhiên, '
    'ngắn gọn, đúng trọng tâm. Người dùng không cần biết tên công cụ, JSON '
    'hay bí danh kỹ thuật.\n'
    'NGUYÊN TẮC:\n'
    '1. Chỉ khẳng định dữ liệu lấy từ kết quả công cụ. Không đoán cấu hình, '
    'IP, SSID, interface hoặc trạng thái router.\n'
    '2. Khi chưa kết nối router, gọi list_devices để lấy alias, sau đó gọi '
    'connect_device với đúng alias. “Kết nối tới router oneai” và “kết nối '
    'tới oneai” cùng nghĩa: alias là oneai; “router” không phải alias.\n'
    '3. Khi cần thông tin từ router, gọi công cụ ngay trong lượt này. Không '
    'nói “đang kiểm tra”, “để tôi xem” hoặc hướng dẫn người dùng tự gọi công cụ.\n'
    '4. Hỏi router có những interface nào hoặc cần chọn interface trước khi '
    'đọc/sửa thì gọi network_list. Hỏi LAN, WAN, IP hay cấu hình mạng thì '
    'gọi network_get. Hỏi Wi-Fi thì gọi wifi_get; không đọc hoặc đoán mật khẩu. '
    'Hỏi đường ra Internet thì gọi route_info. Hỏi lưu lượng thì gọi '
    'traffic_stats.\n'
    '5. Nếu thiếu thông tin bắt buộc để đổi cấu hình, chỉ hỏi một câu ngắn, rõ ràng.\n'
    'ĐỔI CẤU HÌNH IP LAN:\n'
    '6. network_set_preview là luồng ghi cấu hình IP LAN an toàn. Khi người '
    'dùng yêu cầu đổi IP LAN và đã nêu đủ IP cùng netmask, PHẢI gọi ngay '
    'network_set_preview trong cùng lượt; không chỉ trả lời hướng dẫn hoặc '
    'bảo người dùng tự đổi. Tool này tự đọc cấu hình hiện tại, tạo bản xem '
    'trước, mở hộp xác nhận của ứng dụng và chỉ ghi cấu hình sau khi người '
    'dùng bấm Đồng ý. Không gọi thao tác áp dụng nội bộ trực tiếp vì nó không '
    'được cấp cho bạn.\n'
    '7. Đổi IP tĩnh: gọi network_set_preview với interface="lan", '
    'proto="static", ipaddr là IP mới, netmask là netmask mới và gateway '
    'là gateway mới hoặc chuỗi rỗng. Nếu thiếu IP hoặc netmask, chỉ hỏi một '
    'câu để lấy phần còn thiếu.\n'
    '8. Chuyển LAN sang DHCP: gọi network_set_preview với interface="lan", '
    'proto="dhcp" và ipaddr, netmask, gateway đều là chuỗi rỗng. Tool chỉ '
    'xem trước DHCP, nên không nói rằng cấu hình đã được áp dụng.\n'
    '9. Không nói đổi cấu hình thành công trước kết quả tool có status '
    'confirmed. Nếu người dùng hủy hoặc tool báo lỗi, nói rõ router không '
    'được xác nhận thay đổi.\n'
    '10. Khi người dùng chỉ yêu cầu kết nối router, sau connect_device phải '
    'chỉ trả lời theo đúng kết quả tool trả về; không gọi thêm tool đọc cấu '
    'hình trong cùng lượt. Chỉ xác nhận kết nối khi connected là true. Nếu '
    'tool trả lỗi, báo đúng lỗi đó, không nói đã kết nối.';

final RegExp _staticLanCommand = RegExp(
  r'(?:thành|thanh)\s+((?:\d{1,3}\.){3}\d{1,3}).*?'
  r'(?:netmask|subnet\s+mask|mặt\s+nạ)\s+'
  r'((?:\d{1,3}\.){3}\d{1,3})',
  caseSensitive: false,
);

final RegExp _ipv4Address = RegExp(r'(?:\d{1,3}\.){3}\d{1,3}');
final RegExp _gatewayWithNetmask = RegExp(
  r'(?:gateway|cổng\s+ra)\s+(255(?:\.\d{1,3}){3})',
  caseSensitive: false,
);

class StaticLanCommand {
  const StaticLanCommand({required this.ipaddr, required this.netmask});

  final String ipaddr;
  final String netmask;
}

/// Bóc lệnh đổi IP LAN tĩnh khi câu lệnh đã rõ ràng. Có đủ IP và netmask thì
/// mặc định là LAN, vì tool ghi của app chỉ làm được LAN; nói rõ WAN thì để
/// hỏi lại. Với lệnh rủi ro cao này, bóc trực tiếp từ câu người dùng an toàn
/// và tất định hơn là trông chờ model tuân thủ grammar.
StaticLanCommand? parseExplicitStaticLanCommand(String prompt) {
  final value = prompt.toLowerCase();
  if (!_isLanChangeRequest(value)) return null;

  final match = _staticLanCommand.firstMatch(value);
  if (match == null) return null;
  return StaticLanCommand(ipaddr: match.group(1)!, netmask: match.group(2)!);
}

bool _isLanChangeRequest(String value) {
  final wantsChange =
      value.contains('đổi') ||
      value.contains('doi') ||
      value.contains('thay đổi') ||
      value.contains('thay doi') ||
      value.contains('chuyển') ||
      value.contains('chuyen') ||
      value.contains('cấu hình') ||
      value.contains('cau hinh');
  return wantsChange && !RegExp(r'\bwan(?:6)?\b').hasMatch(value);
}

/// Câu hỏi lại do app tự sinh, cho yêu cầu đổi LAN có IP nhưng thiếu dữ liệu
/// đáng tin để gọi tool preview. Thả cho model xử lý thì nó từng trả lời "đã
/// tạo bản xem trước" dù không có tool call nào, và do đó không có hộp thoại.
String? staticLanPreviewClarification(String prompt) {
  final value = prompt.toLowerCase();
  if (!_isLanChangeRequest(value) ||
      parseExplicitStaticLanCommand(prompt) != null ||
      !_ipv4Address.hasMatch(value)) {
    return null;
  }

  if (_gatewayWithNetmask.hasMatch(value)) {
    return 'Bạn ghi gateway là 255.255.255.0; giá trị này thường là netmask, '
        'không phải gateway. Hãy xác nhận lại, ví dụ: “Đổi IP LAN thành '
        '192.168.89.1, netmask 255.255.255.0, gateway để trống”.';
  }

  final hasNetmaskLabel = RegExp(
    r'(?:netmask|subnet\s+mask|mặt\s+nạ)',
    caseSensitive: false,
  ).hasMatch(value);
  if (!hasNetmaskLabel) {
    return 'Để tạo bản xem trước đổi IP LAN, hãy cho biết netmask, ví dụ '
        '255.255.255.0. Router chưa thay đổi cấu hình.';
  }
  return null;
}

/// Tin nhắn chat không bao giờ là xác nhận cho một giao dịch mạng. Chỉ hộp
/// thoại của hệ thống mới giữ ranh giới đó.
bool isBareChatConfirmation(String prompt) {
  switch (prompt.trim().toLowerCase()) {
    case 'xác nhận':
    case 'xac nhan':
    case 'đồng ý':
    case 'dong y':
      return true;
    default:
      return false;
  }
}

/// Danh sách capability đã lấy lúc kết nối, nên đây là câu hỏi cục bộ. Đưa
/// cho model thì nó từng gọi network_get rồi bịa ra một bản tóm tắt LAN.
bool isSupportedToolsRequest(String prompt) {
  final value = prompt.toLowerCase();
  final mentionsTools = value.contains('tool') || value.contains('công cụ');
  return mentionsTools &&
      (value.contains('hỗ trợ') ||
          value.contains('ho tro') ||
          value.contains('danh sách') ||
          value.contains('danh sach'));
}

bool isToolCallComplaint(String prompt) {
  final value = prompt.toLowerCase();
  return value.contains('sai tool') ||
      value.contains('sai tools') ||
      value.contains('gọi sai') ||
      value.contains('goi sai');
}

String supportedToolsCompletionText({
  required String deviceAlias,
  required Set<String> toolNames,
}) {
  if (toolNames.isEmpty) {
    return 'Chưa có danh sách tool vì chưa kết nối tới router.';
  }
  final names = toolNames.toList()..sort();
  return 'Router $deviceAlias hỗ trợ ${names.length} tool: ${names.join(', ')}.';
}

/// Chỉ true khi người dùng đã cho đủ thông tin đổi IP LAN tĩnh. Yêu cầu còn
/// thiếu phải để model hỏi lại, đừng ép nó tạo preview không hợp lệ.
bool requiresExplicitLanPreview(String prompt) {
  return parseExplicitStaticLanCommand(prompt) != null;
}

String? _toolStatus(String result) {
  try {
    final decoded = jsonDecode(result);
    if (decoded is Map) return decoded['status']?.toString();
  } on FormatException {
    // Tool lỗi sẽ được xử lý bên dưới thành kết quả không-thành-công an toàn.
  }
  return null;
}

/// Dựng câu trả lời kết nối từ payload của tool, thay vì để model thuật lại
/// trạng thái mạng mà nó không tự kiểm chứng được.
String connectionCompletionText(String result) {
  try {
    final decoded = jsonDecode(result);
    if (decoded is Map<String, dynamic> && decoded['connected'] == true) {
      final device = decoded['device']?.toString();
      if (device == null || device.isEmpty) {
        return 'Router đã kết nối nhưng không trả về bí danh thiết bị.';
      }

      return 'Đã kết nối thành công đến router $device.';
    }
  } on FormatException {
    // Rơi xuống thông báo lỗi giao thức đúng sự thật bên dưới.
  }

  try {
    final decoded = jsonDecode(result);
    if (decoded is Map && decoded['error'] != null) {
      return 'Không thể kết nối router: ${decoded['error']}';
    }
  } on FormatException {
    // Payload thô không đủ tin cậy để hiển thị như một thành công.
  }
  return 'Không thể xác nhận kết nối router vì kết quả tool không hợp lệ.';
}

/// Kết quả đổi LAN hiển thị cho người dùng do app quyết định, không phải
/// model. Để model không tuyên bố router đã đổi chỉ vì nó thấy một địa chỉ IP
/// trong kết quả đọc.
String lanChangeCompletionText({
  required bool previewAttempted,
  required String? status,
}) {
  if (!previewAttempted) {
    return 'Chưa tạo được bản xem trước đổi IP LAN; router chưa thay đổi cấu hình.';
  }
  switch (status) {
    case 'confirmed':
      return 'Đổi cấu hình LAN thành công và đã xác nhận kết nối lại router.';
    case 'cancelled':
      return 'Bạn đã hủy xác nhận; router không thay đổi cấu hình LAN.';
    case 'preview_confirmed_not_applied':
      return 'Đã xem trước nhưng chưa áp dụng: LAN dùng DHCP nên ứng dụng không biết địa chỉ mới để kết nối lại an toàn.';
    case 'health_confirmation_failed':
      return 'Không xác nhận được sức khỏe router sau khi đổi mạng; IP đã lưu không được cập nhật và router sẽ hoặc đã rollback.';
    case 'apply_disabled':
      return 'Ứng dụng chưa bật luồng áp dụng cấu hình LAN; router không thay đổi.';
    default:
      return 'Không tạo hoặc áp dụng được bản xem trước đổi IP LAN; router chưa được xác nhận thay đổi.';
  }
}

/// Mất kết nối sau khi người dùng đồng ý không chứng minh router còn nguyên:
/// lệnh apply có thể đã chạy và cắt đứt đường quản trị.
String lanChangeUnverifiedText() =>
    'Không thể xác minh kết quả đổi IP LAN sau khi bạn xác nhận. Router có thể '
    'đã áp dụng IP mới; ứng dụng chưa lưu IP mới. Hãy kiểm tra địa chỉ mới hoặc '
    'chờ rollback tự động.';

/// Chuẩn bị một bản ghi để phát lại, cắt bớt kết quả tool quá dài.
LlamaChatMessage _replayable(StoredMessage message) {
  if (message.kind != StoredMessageKind.toolResult ||
      message.content.length <= kMaxToolResultChars) {
    return message.toLlamaMessage();
  }
  return LlamaChatMessage.withContent(
    role: LlamaChatRole.tool,
    content: [
      LlamaToolResultContent(
        id: message.toolCallId,
        name: message.toolName ?? '',
        result: truncateToolResult(message.content),
      ),
    ],
  );
}

/// Điều phối một cuộc trò chuyện: phát lại lịch sử từ SQLite, chạy lượt, và
/// lưu lại mọi thứ lượt đó sinh ra.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.database,
    required this.llm,
    required this.tools,
    required this.toolHost,
    required this.deviceStore,
    required this.conversationId,
  });

  final ChatDatabase database;
  final LlmService llm;

  /// Toàn bộ catalogue. Cái đưa cho model ở mỗi vòng được [toolsFor] lọc ra
  /// từ đây.
  final List<ToolDefinition> tools;

  /// Đọc ở đây vì một lý do: thiết bị đang kết nối quyết định tool nào được
  /// đưa vào prompt.
  final ToolHost toolHost;
  final DeviceStore deviceStore;

  final int conversationId;

  List<StoredMessage> _messages = [];
  List<StoredMessage> get messages => List.unmodifiable(_messages);

  /// Văn bản trợ lý đang chảy về, chưa lưu xuống SQLite.
  String _streamingText = '';
  String get streamingText => _streamingText;

  /// Nhật ký tool của lượt đang chạy, mới nhất ở cuối.
  final List<String> _activeToolLog = [];
  List<String> get activeToolLog => List.unmodifiable(_activeToolLog);

  bool _isGenerating = false;
  bool get isGenerating => _isGenerating;

  String? _turnError;
  String? get turnError => _turnError;

  Future<void> loadHistory() async {
    _messages = await database.listMessages(conversationId);
    notifyListeners();
  }

  Future<void> _runDirectStaticLanPreview(StaticLanCommand command) async {
    final previewTools = tools
        .where((tool) => tool.name == 'network_set_preview')
        .toList(growable: false);
    if (previewTools.isEmpty) {
      await database.insertMessage(
        conversationId: conversationId,
        kind: StoredMessageKind.assistant,
        content: 'Ứng dụng chưa có chức năng xem trước đổi IP LAN.',
      );
      return;
    }

    const id = 'direct_network_set_preview';
    const name = 'network_set_preview';
    final arguments = <String, dynamic>{
      'interface': 'lan',
      'proto': 'static',
      'ipaddr': command.ipaddr,
      'netmask': command.netmask,
      'gateway': '',
    };
    _activeToolLog.add('Đang gọi $name…');
    await database.insertMessage(
      conversationId: conversationId,
      kind: StoredMessageKind.toolCall,
      content: '',
      toolName: name,
      toolCallId: id,
      toolArgumentsJson: jsonEncode(arguments),
    );
    notifyListeners();

    String result;
    var failed = false;
    try {
      result = jsonEncode(await previewTools.first.invoke(arguments));
    } catch (error) {
      failed = true;
      result = jsonEncode({'error': error.toString()});
    }
    _activeToolLog.add(failed ? '$name: lỗi' : '$name: xong');
    await database.insertMessage(
      conversationId: conversationId,
      kind: StoredMessageKind.toolResult,
      content: result,
      toolName: name,
      toolCallId: id,
    );
    await database.insertMessage(
      conversationId: conversationId,
      kind: StoredMessageKind.assistant,
      content: failed
          ? lanChangeUnverifiedText()
          : lanChangeCompletionText(
              previewAttempted: true,
              status: _toolStatus(result),
            ),
    );
    notifyListeners();
  }

  Future<void> _insertAppResponse(String content) async {
    await database.insertMessage(
      conversationId: conversationId,
      kind: StoredMessageKind.assistant,
      content: content,
    );
    notifyListeners();
  }

  Future<void> send(String prompt) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    final directLanCommand = parseExplicitStaticLanCommand(trimmed);
    final requiresLanPreview = directLanCommand != null;
    var previewAttempted = false;
    String? lanChangeStatus;
    String? connectionResult;

    // Mọi lần từ chối đều nói rõ lý do. Trả về im lặng ở đây từng tốn cả buổi
    // debug: khoá engine bị kẹt trông y hệt app phớt lờ thao tác chạm.
    if (_isGenerating || llm.turnInProgress) {
      _turnError =
          'Model đang bận trả lời câu trước. Đợi một chút rồi thử lại.';
      notifyListeners();
      return;
    }
    if (!llm.isReady) {
      _turnError = 'Model chưa sẵn sàng (${llm.status.name}).';
      notifyListeners();
      return;
    }

    _isGenerating = true;
    _turnError = null;
    _streamingText = '';
    _activeToolLog.clear();
    // Phát tín hiệu trước await đầu tiên để ô nhập bị khoá ngay trong frame
    // vừa chạm. Không có nó, các await bên dưới hở ra khe cho cú chạm thứ hai.
    notifyListeners();

    final wasEmpty = await database.isEmpty(conversationId);
    _messages.add(
      await database.insertMessage(
        conversationId: conversationId,
        kind: StoredMessageKind.user,
        content: trimmed,
      ),
    );
    notifyListeners();

    // Đặt tên hội thoại theo câu hỏi đầu tiên cho dễ nhìn ở danh sách.
    if (wasEmpty) {
      await database.renameConversation(
        conversationId,
        trimmed.length > 40 ? '${trimmed.substring(0, 40)}…' : trimmed,
      );
    }

    try {
      if (isBareChatConfirmation(trimmed)) {
        await _insertAppResponse(
          'Xác nhận bằng tin nhắn không áp dụng thay đổi IP. Chỉ nút Đồng ý trong hộp thoại xác nhận mới có hiệu lực.',
        );
        return;
      }

      if (isSupportedToolsRequest(trimmed)) {
        await _insertAppResponse(
          supportedToolsCompletionText(
            deviceAlias: toolHost.deviceAlias,
            toolNames: toolHost.deviceToolNames.intersection(
              kLlmRouterToolNames,
            ),
          ),
        );
        return;
      }

      if (isToolCallComplaint(trimmed)) {
        await _insertAppResponse(
          'Đúng, yêu cầu trước cần dùng danh sách capability đã nhận khi kết nối; không cần gọi network_get.',
        );
        return;
      }

      final lanClarification = staticLanPreviewClarification(trimmed);
      if (lanClarification != null) {
        await _insertAppResponse(lanClarification);
        return;
      }

      // Không để bản preview mang tính an toàn phụ thuộc vào việc model tuân
      // thủ grammar. Chỉ bóc lệnh khi người dùng đã nêu rõ interface, IP và
      // netmask; tool vẫn validate, preview và xin xác nhận trước khi apply.
      if (directLanCommand != null) {
        if (!toolHost.deviceToolNames.contains('network_set_preview')) {
          await _insertAppResponse(
            'Router hiện kết nối không hỗ trợ tạo bản xem trước đổi IP LAN; router chưa thay đổi cấu hình.',
          );
          return;
        }
        await _runDirectStaticLanPreview(directLanCommand);
        return;
      }

      // Engine không nhớ gì giữa các lượt: dựng lại prompt từ lịch sử đã lưu.
      final window = await database.recentMessages(conversationId);
      final routerState = await buildRouterState(
        deviceStore: deviceStore,
        toolHost: toolHost,
      );
      final replayed = <LlamaChatMessage>[
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text:
              '$kSystemPrompt\n\nTRẠNG THÁI ROUTER (do ứng dụng tạo):\n'
              '${jsonEncode(routerState)}',
        ),
        ...window.map(_replayable),
      ];

      await for (final event in runChatTurn(
        llm: llm,
        messages: replayed,
        tools: tools,
        // Được tính lại mỗi vòng, nên connect_device gọi trong chính lượt này
        // sẽ mở khoá các tool đọc cho vòng sau.
        provideTools: () => toolsFor(tools, toolHost.deviceToolNames),
        // Với lệnh đổi LAN tĩnh rõ ràng, chính handler đã đọc network_get
        // trước khi preview. Ép vòng này chỉ được gọi preview để model không
        // dừng sau bước đọc rồi bịa ra kết quả apply.
        requiredToolName: requiresLanPreview ? 'network_set_preview' : null,
      )) {
        switch (event) {
          case TextDelta(:final text):
            // Tóm tắt đổi LAN lấy từ kết quả do app sở hữu bên dưới. Không
            // bao giờ stream lời model nói trước khi có kết quả đó.
            if (!requiresLanPreview) {
              _streamingText += text;
              notifyListeners();
            }

          case ThinkingDelta():
            // Phần suy luận lưu kèm tin nhắn hoàn chỉnh, không stream ra.
            break;

          case ToolCallRequested(:final id, :final name, :final arguments):
            _activeToolLog.add('Đang gọi $name…');
            await database.insertMessage(
              conversationId: conversationId,
              kind: StoredMessageKind.toolCall,
              content: '',
              toolName: name,
              toolCallId: id,
              toolArgumentsJson: jsonEncode(arguments),
            );
            notifyListeners();

          case ToolCallCompleted(
            :final id,
            :final name,
            :final result,
            :final failed,
          ):
            if (requiresLanPreview && name == 'network_set_preview') {
              previewAttempted = true;
              lanChangeStatus = failed ? null : _toolStatus(result);
            }
            if (name == 'connect_device') {
              connectionResult = result;
            }
            _activeToolLog.add(failed ? '$name: lỗi' : '$name: xong');
            await database.insertMessage(
              conversationId: conversationId,
              kind: StoredMessageKind.toolResult,
              // Lưu nguyên văn: không tool đọc nào trả về bí mật. wifi_get
              // không đọc mật khẩu WiFi — đó là thứ làm quy tắc 4 trong
              // kSystemPrompt đúng thật chứ không chỉ là lời khẳng định.
              //
              // Chỉ cần che ở đây nếu sau này có tool ghi trả lại mật khẩu đã
              // staged, và khi đó che giá trị của app chứ không phải của agent.
              content: result,
              toolName: name,
              toolCallId: id,
            );
            notifyListeners();

          case AssistantMessageCompleted(
            :final text,
            :final reasoning,
            :final isFinal,
          ):
            _streamingText = '';
            // Văn bản đi kèm tool call chỉ là lời dạo đầu. Với luồng đổi LAN
            // được bảo vệ thì bỏ hẳn, và chỉ lưu trạng thái suy ra từ kết quả
            // tool khi lượt kết thúc.
            final completedText = requiresLanPreview
                ? (isFinal
                      ? lanChangeCompletionText(
                          previewAttempted: previewAttempted,
                          status: lanChangeStatus,
                        )
                      : '')
                : isFinal && connectionResult != null
                ? connectionCompletionText(connectionResult)
                : text;
            if (completedText.trim().isNotEmpty) {
              await database.insertMessage(
                conversationId: conversationId,
                kind: StoredMessageKind.assistant,
                content: completedText,
                reasoning: reasoning,
              );
            }
            notifyListeners();
        }
      }
    } catch (error) {
      _turnError = error.toString();
    } finally {
      _isGenerating = false;
      _streamingText = '';
      _activeToolLog.clear();
      // Đọc lại để thứ tự hiển thị khớp đúng thứ tự đã lưu.
      await loadHistory();
    }
  }
}
