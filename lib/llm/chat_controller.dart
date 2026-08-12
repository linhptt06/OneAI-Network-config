import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../data/chat_database.dart';
import '../data/chat_models.dart';
import 'llm_service.dart';
import 'secrets.dart';

/// The "act, do not announce" rule exists because a 1.5B model tends to reply
/// "Đang kiểm tra..." and stop, instead of emitting the call. Stating the
/// failure mode as a forbidden behaviour is what suppresses it.
const String kSystemPrompt =
    'Bạn là trợ lý quản trị mạng OpenWrt, trả lời bằng tiếng Việt, ngắn gọn.\n'
    'QUY TẮC BẮT BUỘC:\n'
    '1. Khi cần thông tin từ router, PHẢI gọi công cụ NGAY trong lượt này. '
    'TUYỆT ĐỐI KHÔNG trả lời "đang kiểm tra", "để tôi xem", "chờ chút" — '
    'những câu đó là sai, phải gọi công cụ thay vì hứa hẹn.\n'
    '1b. TUYỆT ĐỐI KHÔNG in ra JSON, khối mã, hay hướng dẫn người dùng tự gọi '
    'công cụ. Người dùng không gọi được công cụ, chỉ bạn gọi được. Cũng KHÔNG '
    'được nói "tôi không truy cập được router" — bạn có công cụ, hãy dùng.\n'
    '2. Hỏi về tên WiFi, SSID, mã hoá, kênh → gọi wifi_get.\n'
    '3. Hỏi về WAN, LAN, địa chỉ IP của router → gọi network_get.\n'
    '4. Hỏi router đang ra Internet đường nào → gọi route_info. '
    'Hỏi về lưu lượng đã dùng → gọi traffic_stats.\n'
    '5. Phải gọi connect_device trước các công cụ khác.\n'
    '6. Chỉ trả lời dựa trên kết quả công cụ trả về. Không bịa tên interface, '
    'SSID hay giá trị cấu hình.\n'
    '7. Không biết tên interface hay section thì BỎ TRỐNG tham số để dùng mặc '
    'định. Công cụ trả về "error" thì đọc "hint", thử lại nhiều nhất một lần '
    'rồi báo người dùng.\n'
    '8. KHÔNG đọc được mật khẩu WiFi — router không cho phép. Được hỏi thì nói '
    'thẳng là không xem được, TUYỆT ĐỐI KHÔNG đoán một mật khẩu nào.';

/// Longest tool result replayed back into a prompt.
///
/// A device with many wireless interfaces can produce a result far larger than
/// the reply itself, and several of those in the window crowd out the tool
/// schemas. The UI still shows the full text; only the copy the model re-reads
/// on later turns is capped.
const int kMaxReplayedToolResultChars = 700;

/// Prepares a stored row for replay, shortening over-long tool results.
LlamaChatMessage _replayable(StoredMessage message) {
  if (message.kind != StoredMessageKind.toolResult ||
      message.content.length <= kMaxReplayedToolResultChars) {
    return message.toLlamaMessage();
  }
  return LlamaChatMessage.withContent(
    role: LlamaChatRole.tool,
    content: [
      LlamaToolResultContent(
        id: message.toolCallId,
        name: message.toolName ?? '',
        result:
            '${message.content.substring(0, kMaxReplayedToolResultChars)}'
            '… [đã cắt bớt — gọi lại công cụ nếu cần đầy đủ]',
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
    required this.conversationId,
  });

  final ChatDatabase database;
  final LlmService llm;
  final List<ToolDefinition> tools;
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
      _turnError = 'Model đang bận trả lời câu trước. Đợi một chút rồi thử lại.';
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
      final replayed = <LlamaChatMessage>[
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: kSystemPrompt,
        ),
        ...window.map(_replayable),
      ];

      await for (final event in runChatTurn(
        llm: llm,
        messages: replayed,
        tools: tools,
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
              // The model was handed the real value in-memory; what lands on
              // disk has WiFi passphrases replaced with dots.
              content: redactSecrets(result),
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
