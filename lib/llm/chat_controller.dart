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
    'ĐỔI IP LAN AN TOÀN:\n'
    '6. Khi người dùng muốn đổi IP LAN hoặc kiểu kết nối mạng, luôn đọc '
    'network_get trước. Chỉ dùng network_set_preview để tạo bản xem trước, '
    'chưa áp dụng cấu hình. Chỉ hỗ trợ proto static hoặc dhcp. Với static, '
    'cần IP và netmask hợp lệ; gateway có thể để trống. Với dhcp, không gửi '
    'IP, netmask hoặc gateway.\n'
    '7. Sau preview, ứng dụng sẽ hiển thị thay đổi và cảnh báo có thể mất kết '
    'nối. Không tự khẳng định đã đổi cấu hình khi người dùng chưa xác nhận. '
    'Khi người dùng hủy, không có thay đổi nào được áp dụng.';

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

  Future<void> send(String prompt) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;

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
      )) {
        switch (event) {
          case TextDelta(:final text):
            _streamingText += text;
            notifyListeners();

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

          case AssistantMessageCompleted(:final text, :final reasoning):
            _streamingText = '';
            if (text.trim().isNotEmpty) {
              await database.insertMessage(
                conversationId: conversationId,
                kind: StoredMessageKind.assistant,
                content: text,
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
