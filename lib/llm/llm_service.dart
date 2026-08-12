import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'secrets.dart';

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
    'hf://Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf';

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
        modelParams: const ModelParams(
          // Back to 4096. The 8 tool schemas plus system prompt come to about
          // 1.2k tokens, leaving ~2.8k for history and the reply, which the
          // 10-message window fits. 8192 doubled the KV cache and slowed
          // prefill for headroom that was not being used.
          contextSize: 4096,
          // CPU-only: Android GPU offload through llama.cpp is unreliable
          // across vendors, and a 1.5B Q4 model is fast enough on CPU.
          gpuLayers: 0,
        ),
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
  const AssistantMessageCompleted(this.text, this.reasoning);
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
Stream<TurnEvent> runChatTurn({
  required LlmService llm,
  required List<LlamaChatMessage> messages,
  required List<ToolDefinition> tools,
  GenerationParams params = const GenerationParams(maxTokens: 512),
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
  required GenerationParams params,
  required int maxToolRounds,
}) async* {
  for (var round = 0; round <= maxToolRounds; round++) {
    final text = StringBuffer();
    final thinking = StringBuffer();
    final builders = <int, _ToolCallBuilder>{};

    // Past the round budget, stop offering tools so the model is forced to
    // answer with what it already has instead of looping again.
    final offerTools = round < maxToolRounds;

    await for (final chunk in engine.create(
      messages,
      params: params,
      tools: offerTools ? tools : null,
      toolChoice: offerTools ? ToolChoice.auto : ToolChoice.none,
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
      yield AssistantMessageCompleted(text.toString(), reasoning);
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
      yield AssistantMessageCompleted(text.toString(), reasoning);
    }

    for (final index in builders.keys.toList()..sort()) {
      final builder = builders[index]!;
      final name = builder.name ?? '';
      final id = builder.id ?? 'call_$index';
      final arguments = builder.decodedArguments;

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
            // The model needs the real value to answer; the marker is only a
            // signal to the persistence layer, so it is dropped here.
            LlamaToolResultContent(
              id: id,
              name: name,
              result: stripSecretMarkers(result),
            ),
          ],
        ),
      );
    }
  }
}
