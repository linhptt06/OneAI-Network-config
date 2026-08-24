import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Model mặc định: Qwen2.5-3B-Instruct Q4_K_M (~2 GB). Chat template của nó
/// sinh `<tool_call>` / `<tool_response>` nên tool call mới chạy được.
///
/// Tên repo và file phân biệt hoa thường; gõ sai thì Hugging Face trả 401 chứ
/// không phải 404.
///
/// Hợp với điện thoại 8 GB. Trên emulator 4 GB thì thiếu RAM, một lượt mất
/// ~10 phút — dùng [kModel3bSmaller].
const String kDefaultModelSource =
    'hf://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf';

/// Các lựa chọn thay thế, kèm dung lượng đã đo. Khi tính RAM nhớ cộng thêm
/// ~300 MB KV cache ở `contextSize: 8192`.
const String kModel3b =
    'hf://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf'; // 2007 MB
const String kModel3bSmaller =
    'hf://bartowski/Qwen2.5-3B-Instruct-GGUF/Qwen2.5-3B-Instruct-Q3_K_M.gguf'; // 1517 MB

enum LlmStatus { idle, downloading, loading, ready, error }

/// Quản lý vòng đời [LlamaEngine]. Mọi hội thoại dùng chung một engine; lịch
/// sử nằm trong SQLite chứ không trong engine.
class LlmService extends ChangeNotifier {
  LlamaEngine? _engine;

  LlmStatus _status = LlmStatus.idle;
  LlmStatus get status => _status;

  /// 0..1 khi đang tải, null khi chưa biết tổng dung lượng.
  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _modelSource = kDefaultModelSource;
  String get modelSource => _modelSource;

  bool get isReady => _status == LlmStatus.ready && _engine != null;

  /// llama.cpp chỉ sinh được một luồng tại một thời điểm. Khoá đặt ở engine
  /// chứ không ở UI, vì hot reload hay mở lại màn hình sẽ tạo controller thứ
  /// hai tưởng engine đang rảnh.
  bool _turnInProgress = false;
  bool get turnInProgress => _turnInProgress;

  /// Giành engine cho một lượt. False nếu đã có lượt đang chạy, để bên gọi từ
  /// chối gọn thay vì để llama.cpp ném lỗi.
  bool beginTurn() {
    if (_turnInProgress) return false;
    _turnInProgress = true;
    return true;
  }

  void endTurn() {
    _turnInProgress = false;
  }

  LlamaEngine get engine {
    final engine = _engine;
    if (engine == null || _status != LlmStatus.ready) {
      throw StateError('Model chưa sẵn sàng.');
    }
    return engine;
  }

  /// Tải model (nếu cần) rồi nạp. Android không có cache dùng chung nên thư
  /// mục cache ghim vào vùng riêng của app.
  Future<void> load({String? source}) async {
    if (_status == LlmStatus.downloading || _status == LlmStatus.loading) {
      return;
    }

    _modelSource = source ?? _modelSource;
    _errorMessage = null;
    _downloadProgress = null;
    // Model đã cache không báo tiến độ, nên chỉ vào trạng thái downloading
    // khi thực sự có tải về.
    _setStatus(LlmStatus.loading);

    try {
      await _engine?.dispose();
      final engine = LlamaEngine(LlamaBackend());
      _engine = engine;

      final cacheDir = p.join(
        (await getApplicationSupportDirectory()).path,
        'models',
      );

      await engine.loadModelSource(
        ModelSource.parse(_modelSource),
        modelParams: const ModelParams(contextSize: 8192, gpuLayers: 0),
        options: ModelLoadOptions(cacheDirectory: cacheDir),
        onProgress: (progress) {
          _downloadProgress = progress.fraction;
          // Tải xong thì về `loading`: bước map model cũng chậm.
          _status = (progress.fraction ?? 0) >= 1.0
              ? LlmStatus.loading
              : LlmStatus.downloading;
          notifyListeners();
        },
      );

      _downloadProgress = null;
      _setStatus(LlmStatus.ready);
    } catch (error) {
      _errorMessage = error.toString();
      _engine = null;
      _setStatus(LlmStatus.error);
    }
  }

  void _setStatus(LlmStatus status) {
    _status = status;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Sự kiện trong một lượt
// ---------------------------------------------------------------------------

/// Một bước quan sát được của lượt chat. Một câu hỏi có thể sinh nhiều bước:
/// văn bản, tool call, rồi văn bản tiếp.
sealed class TurnEvent {
  const TurnEvent();
}

/// Một mảnh văn bản của trợ lý.
class TextDelta extends TurnEvent {
  final String text;
  const TextDelta(this.text);
}

/// Một mảnh suy luận, với model có phát ra phần này.
class ThinkingDelta extends TurnEvent {
  final String text;
  const ThinkingDelta(this.text);
}

/// Model yêu cầu chạy tool.
class ToolCallRequested extends TurnEvent {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  const ToolCallRequested({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// Tool chạy xong; [result] là payload JSON gửi lại cho model.
class ToolCallCompleted extends TurnEvent {
  final String id;
  final String name;
  final String result;
  final bool failed;
  const ToolCallCompleted({
    required this.id,
    required this.name,
    required this.result,
    this.failed = false,
  });
}

/// Trợ lý sinh xong một tin nhắn hoàn chỉnh.
class AssistantMessageCompleted extends TurnEvent {
  final String text;
  final String? reasoning;

  /// False khi văn bản đi kèm tool call — đó là lời dạo đầu, chưa phải câu
  /// trả lời có căn cứ.
  final bool isFinal;

  const AssistantMessageCompleted(
    this.text,
    this.reasoning, {
    this.isFinal = true,
  });
}

// ---------------------------------------------------------------------------
// Vòng lặp gọi tool
// ---------------------------------------------------------------------------

/// Gom các mảnh tool call theo luồng thành lời gọi hoàn chỉnh.
class _ToolCallBuilder {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();

  Map<String, dynamic> get decodedArguments {
    if (arguments.isEmpty) return {};
    try {
      final decoded = jsonDecode(arguments.toString());
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }
}

/// Tham số sinh cho một lượt. `temp: 0` giữ tham số tool lặp lại được.
const GenerationParams kTurnParams = GenerationParams(
  maxTokens: 768,
  temp: 0.0,
  topK: 0,
  topP: 1.0,
  penalty: 1.0,
);

/// Độ dài tối đa của kết quả tool khi phát lại vào prompt. Router nhiều
/// interface có thể trả về dài hơn cả câu trả lời, chiếm chỗ của schema tool.
/// UI vẫn hiện đầy đủ; chỉ bản model đọc lại mới bị cắt.
const int kMaxToolResultChars = 1500;
String truncateToolResult(String result) => result.length <= kMaxToolResultChars
    ? result
    : '${result.substring(0, kMaxToolResultChars)}'
          '… [đã cắt bớt — gọi lại công cụ nếu cần đầy đủ]';

/// Bộ tool và cách chọn tool cho một vòng. Khi bắt buộc gọi, danh sách rút
/// còn một định nghĩa để ToolChoice.required thành ràng buộc grammar thật sự.
class ToolRoundPlan {
  const ToolRoundPlan({required this.tools, required this.toolChoice});

  final List<ToolDefinition>? tools;
  final ToolChoice toolChoice;
}

/// Thu hẹp một vòng về đúng [requiredToolName] cho tới khi tool đó được gọi.
/// Tự vô hiệu nếu router không khai báo tool, để bên gọi báo "không hỗ trợ"
/// thay vì bịa thành công.
ToolRoundPlan planToolRound({
  required List<ToolDefinition>? offered,
  required String? requiredToolName,
  required bool requiredToolHasBeenCalled,
}) {
  if (offered == null) {
    return const ToolRoundPlan(tools: null, toolChoice: ToolChoice.none);
  }

  if (requiredToolName != null && !requiredToolHasBeenCalled) {
    final required = offered
        .where((tool) => tool.name == requiredToolName)
        .toList(growable: false);
    if (required.isNotEmpty) {
      return ToolRoundPlan(tools: required, toolChoice: ToolChoice.required);
    }
  }
  return ToolRoundPlan(tools: offered, toolChoice: ToolChoice.auto);
}

/// Chạy trọn một lượt chat, gọi tool mỗi khi model yêu cầu.
///
/// [messages] là lịch sử phát lại, được nối thêm tại chỗ. Bên gọi lưu trữ từ
/// các sự kiện phát ra, không phải từ danh sách này. Dừng khi model trả lời mà
/// không xin tool, hoặc sau [maxToolRounds] vòng.
///
/// Hai danh sách tool, cố ý tách:
/// - [tools]: toàn bộ catalogue, dùng để tra tên. Tool không đưa ra ở vòng này
///   vẫn chạy nếu model đòi, để nó trả lời bằng `hint` của chính nó.
/// - [provideTools]: tập con đưa vào prompt, gọi lại mỗi vòng vì
///   `connect_device` chạy giữa lượt và mở khoá thêm tool đọc.
Stream<TurnEvent> runChatTurn({
  required LlmService llm,
  required List<LlamaChatMessage> messages,
  required List<ToolDefinition> tools,
  List<ToolDefinition> Function()? provideTools,
  String? requiredToolName,
  GenerationParams params = kTurnParams,
  int maxToolRounds = 4,
}) async* {
  if (!llm.beginTurn()) {
    throw StateError(
      'Model đang bận trả lời một câu hỏi khác. Hãy đợi câu trước xong.',
    );
  }
  try {
    // Đọc `llm.engine` bên trong try: nếu đặt trước try, lỗi "model chưa sẵn
    // sàng" sẽ bỏ qua finally và kẹt engine suốt phiên.
    yield* _runChatTurnLocked(
      engine: llm.engine,
      messages: messages,
      tools: tools,
      provideTools: provideTools ?? () => tools,
      requiredToolName: requiredToolName,
      params: params,
      maxToolRounds: maxToolRounds,
    );
  } finally {
    // Nhả cả khi stream bị huỷ giữa chừng, nếu không một lượt bỏ dở là kẹt
    // engine suốt phiên.
    llm.endTurn();
  }
}

Stream<TurnEvent> _runChatTurnLocked({
  required LlamaEngine engine,
  required List<LlamaChatMessage> messages,
  required List<ToolDefinition> tools,
  required List<ToolDefinition> Function() provideTools,
  required String? requiredToolName,
  required GenerationParams params,
  required int maxToolRounds,
}) async* {
  var requiredToolHasBeenCalled = false;
  for (var round = 0; round <= maxToolRounds; round++) {
    final text = StringBuffer();
    final thinking = StringBuffer();
    final builders = <int, _ToolCallBuilder>{};

    // Hết hạn mức vòng thì ngừng đưa tool, ép model trả lời bằng cái đã có.
    final offerTools = round < maxToolRounds;

    // Hỏi lại mỗi vòng: kết nối thiết bị giữa lượt làm đổi danh sách tool.
    final offered = offerTools ? provideTools() : null;
    final roundPlan = planToolRound(
      offered: offered,
      requiredToolName: requiredToolName,
      requiredToolHasBeenCalled: requiredToolHasBeenCalled,
    );

    await for (final chunk in engine.create(
      messages,
      params: params,
      tools: roundPlan.tools,
      toolChoice: roundPlan.toolChoice,
    )) {
      if (chunk.choices.isEmpty) continue;
      final delta = chunk.choices.first.delta;

      if (delta.content != null && delta.content!.isNotEmpty) {
        text.write(delta.content);
        yield TextDelta(delta.content!);
      }
      if (delta.thinking != null && delta.thinking!.isNotEmpty) {
        thinking.write(delta.thinking);
        yield ThinkingDelta(delta.thinking!);
      }
      for (final call in delta.toolCalls ?? const []) {
        final builder = builders.putIfAbsent(call.index, _ToolCallBuilder.new);
        if (call.id != null) builder.id = call.id;
        if (call.function?.name != null) builder.name = call.function!.name;
        if (call.function?.arguments != null) {
          builder.arguments.write(call.function!.arguments);
        }
      }
    }

    final reasoning = thinking.isEmpty ? null : thinking.toString();

    // Không xin tool nào — lượt kết thúc.
    if (builders.isEmpty) {
      yield AssistantMessageCompleted(
        text.toString(),
        reasoning,
        isFinal: true,
      );
      messages.add(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.assistant,
          text: text.toString(),
        ),
      );
      return;
    }

    // Văn bản đi kèm tool call vẫn đáng hiện.
    if (text.isNotEmpty) {
      yield AssistantMessageCompleted(
        text.toString(),
        reasoning,
        isFinal: false,
      );
    }

    for (final index in builders.keys.toList()..sort()) {
      final builder = builders[index]!;
      final name = builder.name ?? '';
      final id = builder.id ?? 'call_$index';
      final arguments = builder.decodedArguments;
      if (name == requiredToolName) requiredToolHasBeenCalled = true;

      yield ToolCallRequested(id: id, name: name, arguments: arguments);

      messages.add(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: [
            LlamaToolCallContent(
              id: id,
              name: name,
              arguments: arguments,
              rawJson: builder.arguments.toString(),
            ),
          ],
        ),
      );

      String result;
      var failed = false;
      // Tra trong toàn bộ catalogue, không phải danh sách của vòng này. Từ
      // chối lời gọi mà model còn nhớ thì mất luôn hint — thứ bảo nó dừng.
      final tool = tools.where((t) => t.name == name).firstOrNull;
      if (tool == null) {
        failed = true;
        result = jsonEncode({'error': 'Không có tool tên "$name"'});
      } else {
        try {
          result = jsonEncode(await tool.invoke(arguments));
        } catch (error) {
          // Trả về dạng dữ liệu để model thử lại với tham số khác, thay vì
          // hỏng cả lượt.
          failed = true;
          result = jsonEncode({'error': error.toString()});
        }
      }

      yield ToolCallCompleted(
        id: id,
        name: name,
        result: result,
        failed: failed,
      );

      messages.add(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.tool,
          content: [
            LlamaToolResultContent(
              id: id,
              name: name,
              result: truncateToolResult(result),
            ),
          ],
        ),
      );
    }
  }
}
