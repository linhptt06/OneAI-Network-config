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

/// The "act, do not announce" rule exists because a 1.5B model tends to reply
/// "Đang kiểm tra..." and stop, instead of emitting the call. Stating the
/// failure mode as a forbidden behaviour is what suppresses it.
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

/// Parses an unambiguous static LAN command. A fully specified IP/netmask
/// request defaults to LAN because this app's mutation tool is LAN-only; an
/// explicit WAN request is left for a clarification instead. A model is still
/// useful for ordinary router questions, but a small local model cannot
/// reliably honour a mandatory function-call grammar. For this high-risk
/// command, dispatching from explicit user input is safer and deterministic.
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

/// Returns an app-owned clarification for a LAN change that contains an IP
/// but not enough trustworthy data to invoke the preview tool. Letting this
/// fall through to the model used to allow an ungrounded "đã tạo bản xem
/// trước" reply, even though no tool call (and therefore no dialog) occurred.
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

/// A chat message is never a confirmation for a network transaction. The
/// native dialog owns that boundary and blocks input while it is visible.
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

/// Capability discovery already ran while connecting. Asking which tools are
/// available is a local question; sending it to the model used to make it call
/// network_get and then invent a LAN summary.
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

/// True only when the user supplied enough information for a static LAN
/// change. Incomplete requests must stay conversational so the model can ask
/// its one missing question instead of being forced into an invalid preview.
bool requiresExplicitLanPreview(String prompt) {
  return parseExplicitStaticLanCommand(prompt) != null;
}

String? _toolStatus(String result) {
  try {
    final decoded = jsonDecode(result);
    if (decoded is Map) return decoded['status']?.toString();
  } on FormatException {
    // Tool failures are represented below as a safe non-success result.
  }
  return null;
}

/// Creates the connection reply from the tool payload instead of asking the
/// model to restate network state it cannot independently verify.
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
    // Fall through to a truthful protocol-error message below.
  }

  try {
    final decoded = jsonDecode(result);
    if (decoded is Map && decoded['error'] != null) {
      return 'Không thể kết nối router: ${decoded['error']}';
    }
  } on FormatException {
    // The raw payload is not trustworthy enough to display as a success.
  }
  return 'Không thể xác nhận kết nối router vì kết quả tool không hợp lệ.';
}

List<String> _toolNames(Object? value) {
  if (value is! List) return const [];
  final names = value.whereType<String>().toList()..sort();
  return names;
}

/// The user-facing result for a LAN mutation is app-owned, not model-owned.
/// This deliberately prevents an ungrounded completion from claiming that a
/// router changed merely because the model saw an IP address in a read result.
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

/// A transport failure after the user approves is not evidence that the router
/// stayed unchanged: apply may already have cut the management connection.
String lanChangeUnverifiedText() =>
    'Không thể xác minh kết quả đổi IP LAN sau khi bạn xác nhận. Router có thể '
    'đã áp dụng IP mới; ứng dụng chưa lưu IP mới. Hãy kiểm tra địa chỉ mới hoặc '
    'chờ rollback tự động.';

/// Longest tool result replayed back into a prompt.
///
/// A device with many wireless interfaces can produce a result far larger than
/// the reply itself, and several of those in the window crowd out the tool
/// schemas. The UI still shows the full text; only the copy the model re-reads
/// on later turns is capped.

/// Prepares a stored row for replay, shortening over-long tool results.
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

/// Drives one conversation: replays history from SQLite, runs the turn, and
/// persists everything the turn produces.
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

  /// The whole tool catalogue. What is offered to the model on a given round is
  /// narrowed from it by [toolsFor]; see [send].
  final List<ToolDefinition> tools;

  /// Read here for one reason: the connected device decides which read tools
  /// belong in the prompt.
  final ToolHost toolHost;
  final DeviceStore deviceStore;

  final int conversationId;

  List<StoredMessage> _messages = [];
  List<StoredMessage> get messages => List.unmodifiable(_messages);

  /// Assistant text streaming in right now, before it is persisted.
  String _streamingText = '';
  String get streamingText => _streamingText;

  /// Tool activity for the in-flight turn, newest last.
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

    // Each refusal reports why. Returning silently here once cost a debugging
    // session: a stuck engine lock looked exactly like the app ignoring taps.
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
    // Published before the first await, so the composer is disabled in the
    // same frame as the tap. Without this the awaits below leave a window in
    // which a second tap starts another turn.
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

    // Title the thread after its first prompt, so the list is scannable.
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

      // Do not make a safety-critical preview depend on the 3B model obeying
      // a function-call grammar. The command is parsed only after the user
      // supplied an explicit interface, IP and netmask; the tool itself still
      // validates, previews and asks for native UI approval before apply.
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

      // The engine is stateless between turns: rebuild the prompt from the
      // persisted history every time.
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
        // Evaluated per round by the turn loop, so a connect_device call made
        // in this same turn unlocks the device's read tools for the next round.
        provideTools: () => toolsFor(tools, toolHost.deviceToolNames),
        // For an explicit static LAN request, the handler itself reads
        // network_get before preview. Restricting this model round to preview
        // removes the 3B model's opportunity to stop after a read and invent
        // an apply result.
        requiredToolName: requiresLanPreview ? 'network_set_preview' : null,
      )) {
        switch (event) {
          case TextDelta(:final text):
            // A LAN mutation summary is derived from the app-owned outcome
            // below. Never stream a model claim before that outcome exists.
            if (!requiresLanPreview) {
              _streamingText += text;
              notifyListeners();
            }

          case ThinkingDelta():
            // Reasoning is persisted with the finished message instead of
            // being streamed into the transcript.
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
              // Stored verbatim. No read tool returns a secret: the agent's
              // wifi_get does not read the passphrase, which is what makes the
              // claim in its description and in rule 8 true rather than merely
              // asserted. A redaction layer used to sit here for a value nothing
              // ever produced — it was removed because a protection that never
              // fires is indistinguishable from one that does not exist, and it
              // told the model to call a tool for a passphrase it cannot get.
              //
              // A write tool that echoes a staged passphrase back would change
              // this. That is the point to reintroduce redaction, on the value
              // the app itself supplied — not on the agent's output.
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
            // Prose emitted with a tool call is a preamble, not a finished
            // answer. Suppress it for a protected LAN change. When the turn
            // is final, persist only a status derived from the tool outcome.
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
      // Re-read so the displayed order matches the persisted order exactly.
      await loadHistory();
    }
  }
}
