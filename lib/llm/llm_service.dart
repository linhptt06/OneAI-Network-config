import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Default model: small enough for a phone, and its chat template renders
/// `<tool_call>` / `<tool_response>`, which is what makes tool calling work.
///
/// Repo and file name are case-sensitive. Hugging Face answers 401 (not 404)
/// for a path that does not exist, so a typo here surfaces as an auth error.
/// 1.5B rather than 3B: on a 4 GB emulator backed by a 7.7 GB host, the 3B
/// model pushed the host into swapping and a single turn took ~10 minutes.
/// The bottleneck was memory pressure, not model size as such — a phone with
/// 8 GB runs 3B comfortably.
const String kDefaultModelSource =
    'hf://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf';

/// Alternatives, with measured file sizes.
///
/// On top of the file itself the runtime needs roughly 150 MB of KV cache at
/// the current `contextSize: 4096`, so a 4 GB emulator with Android already
/// resident fits the 1.5B model comfortably and the 3B one only barely.
const String kModel3b =
    'hf://Qwen/Qwen2.5-3B-Instruct-GGUF/qwen2.5-3b-instruct-q4_k_m.gguf'; // 2007 MB
const String kModel3bSmaller =
    'hf://bartowski/Qwen2.5-3B-Instruct-GGUF/Qwen2.5-3B-Instruct-Q3_K_M.gguf'; // 1517 MB

enum LlmStatus { idle, downloading, loading, ready, error }

/// Owns the [LlamaEngine] lifecycle: download, load, unload.
///
/// One engine is shared by every conversation; the conversation history lives
/// in SQLite, not in the engine.
class LlmService extends ChangeNotifier {
  LlamaEngine? _engine;

  LlmStatus _status = LlmStatus.idle;
  LlmStatus get status => _status;

  /// 0..1 while downloading, or null when the total size is unknown.
  double? _downloadProgress;
  double? get downloadProgress => _downloadProgress;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  String _modelSource = kDefaultModelSource;
  String get modelSource => _modelSource;

  bool get isReady => _status == LlmStatus.ready && _engine != null;

  /// Whether a turn is currently using the engine.
  ///
  /// llama.cpp allows exactly one generation at a time. Guarding only in the
  /// UI is not enough: each chat screen builds its own controller, so a hot
  /// reload or a reopened screen can produce a second controller that believes
  /// the engine is idle. The lock therefore lives with the engine itself.
  bool _turnInProgress = false;
  bool get turnInProgress => _turnInProgress;

  /// Claims the engine for one turn. Returns false if a turn is already
  /// running, so the caller can refuse cleanly instead of letting llama.cpp
  /// raise "generation is already in progress".
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

  /// Downloads (if needed) and loads the model.
  ///
  /// On Android there is no implicit shared model cache, so the cache directory
  /// is pinned to app-private storage.
  Future<void> load({String? source}) async {
    if (_status == LlmStatus.downloading || _status == LlmStatus.loading) {
      return;
    }

    _modelSource = source ?? _modelSource;
    _errorMessage = null;
    _downloadProgress = null;
    // Starts as `loading`: a cached model never reports progress, so the
    // downloading state is entered only if a download actually begins.
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
          // Back to `loading` once the bytes are down and llama.cpp starts
          // mapping the model, which is itself slow on a phone.
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
// Turn events
// ---------------------------------------------------------------------------

/// One observable step of a chat turn.
///
/// A single user prompt can produce several of these: prose, then a tool call,
/// then more prose after the tool result is fed back.
sealed class TurnEvent {
  const TurnEvent();
}

/// A fragment of assistant prose.
class TextDelta extends TurnEvent {
  final String text;
  const TextDelta(this.text);
}

/// A fragment of model reasoning, for models that expose it.
class ThinkingDelta extends TurnEvent {
  final String text;
  const ThinkingDelta(this.text);
}

/// The model asked to run a tool.
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

/// A tool finished; [result] is the JSON-encoded payload sent back to the model.
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

/// The assistant produced a complete prose message (one round of the loop).
class AssistantMessageCompleted extends TurnEvent {
  final String text;
  final String? reasoning;

  /// False only for prose emitted alongside a tool call. Callers need this to
  /// avoid presenting a model preamble as a completed, grounded answer.
  final bool isFinal;

  const AssistantMessageCompleted(
    this.text,
    this.reasoning, {
    this.isFinal = true,
  });
}

// ---------------------------------------------------------------------------
// Tool-call loop
// ---------------------------------------------------------------------------

/// Accumulates streamed tool-call fragments into whole calls.
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

/// Runs one chat turn to completion, executing tools as the model requests them.
///
/// [messages] is the replayed history; it is appended to in place as the turn
/// progresses so each follow-up request sees the tool calls and results from
/// earlier rounds. Callers persist from the emitted events, not from this list.
/// The loop stops when the model answers without asking for a tool, or after
/// [maxToolRounds] rounds — the bound guards against a model that keeps
/// re-requesting the same tool forever.
///
/// Two tool lists, deliberately:
///
/// - [tools] is the whole catalogue, and it is what a requested name is looked
///   up in. A tool that was not offered this round still runs if the model asks
///   for it, so it can answer with its own `hint` and `valid_values` instead of
///   a bare "no such tool".
/// - [provideTools] returns the subset whose schemas go into the prompt, and is
///   called again at the start of *every* round rather than once per turn:
///   `connect_device` runs inside a turn, so the round after it must be able to
///   offer the read tools it just unlocked. Defaults to the whole catalogue.
///
/// Changing the offered set mid-turn invalidates the prompt prefix and makes
/// llama.cpp prefill again, which is the largest cost on a phone. It is paid
/// only on connect and disconnect — a few times per session — so it amortises.
/// If measurement says otherwise, freeze the set for the whole turn and accept
/// that connect + read takes two turns.
const GenerationParams kTurnParams = GenerationParams(
  maxTokens: 768,
  temp: 0.0,
  topK: 0,
  topP: 1.0,
  penalty: 1.0,
);

const int kMaxToolResultChars = 1500;
String truncateToolResult(String result) => result.length <= kMaxToolResultChars
    ? result
    : '${result.substring(0, kMaxToolResultChars)}'
          '… [đã cắt bớt — gọi lại công cụ nếu cần đầy đủ]';

/// The tool set and choice for one model round.
///
/// A required call is limited to one definition. ToolChoice.required then
/// becomes a grammar-level constraint rather than a hope expressed in prose.
class ToolRoundPlan {
  const ToolRoundPlan({required this.tools, required this.toolChoice});

  final List<ToolDefinition>? tools;
  final ToolChoice toolChoice;
}

/// Narrows one round to [requiredToolName] until that tool has been called.
///
/// The policy remains inert when the connected router does not advertise the
/// tool. In that case the caller can return a truthful not-supported result
/// instead of inventing success.
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
    // `llm.engine` throws when the model is not ready. Reading it inside the
    // try is what guarantees the lock is released: evaluated before it, a
    // throw here would skip the finally and wedge the engine for the rest of
    // the session, silently swallowing every later message.
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
    // Released even when the stream is cancelled mid-generation, otherwise a
    // single abandoned turn would wedge the engine for the rest of the session.
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

    // Past the round budget, stop offering tools so the model is forced to
    // answer with what it already has instead of looping again.
    final offerTools = round < maxToolRounds;

    // Asked again every round, not once per turn: a tool called in this turn
    // can change what is available for the next round — connecting to a device
    // is exactly that.
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

    // No tool requested — the turn is over.
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

    // Any prose that came alongside the tool call is still worth showing.
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
      // Looked up in the whole catalogue, not in what was offered this round.
      // Offering less is a token saving; refusing a call the model still
      // remembers from earlier in the conversation gains nothing, and costs the
      // tool's own hint — which is the thing that tells the model to stop.
      final tool = tools.where((t) => t.name == name).firstOrNull;
      if (tool == null) {
        failed = true;
        result = jsonEncode({'error': 'Không có tool tên "$name"'});
      } else {
        try {
          result = jsonEncode(await tool.invoke(arguments));
        } catch (error) {
          // Reported back to the model as data: it can then apologise or retry
          // with different arguments instead of the turn failing outright.
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
