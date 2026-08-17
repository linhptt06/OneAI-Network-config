/// Wire contract between the app and the on-router agent.
///
/// Pure data and codecs: no SSH, no I/O, so both sides of the contract can be
/// exercised in unit tests without a router.
///
/// The agent is invoked once per request. The request travels on stdin and the
/// response on stdout, both as a single JSON object. Nothing is passed as a
/// shell argument, which removes quoting and argument-length limits from the
/// threat model entirely.
library;

import 'dart:convert';

/// Protocol revision the app speaks.
///
/// The agent reports the revision it implements in its `list` response; the
/// client refuses to drive an agent that does not match, rather than
/// discovering the mismatch halfway through a configuration change.
const int kAgentContractVersion = 1;

/// Methods the agent exposes.
///
/// Reads go through [call] and return immediately. Writes are two-phase
/// because a human approves the change in between: [stage] applies `uci set`
/// without committing and reports the diff, then [commit] or [revert]
/// resolves it.
enum AgentMethod {
  list,
  call,
  stage,
  commit,
  revert;

  String get wireName => name;
}

/// What the agent says it can do.
///
/// Deliberately carries **names only**, never descriptions. Tool descriptions
/// are rendered into the model's prompt, so accepting them from the device
/// would let a compromised router inject instructions into the model. The app
/// keeps ownership of every word the model reads; the device only gets to say
/// which of the app's tools it supports.
class AgentCapabilities {
  const AgentCapabilities({
    required this.contractVersion,
    required this.toolNames,
    this.agentVersion,
    this.board,
    this.release,
    this.target,
  });

  final int contractVersion;
  final Set<String> toolNames;

  /// Free-form build identifier, for diagnostics only.
  final String? agentVersion;

  /// Device identity, reported by the agent rather than probed by the app.
  ///
  /// The app used to read `/tmp/sysinfo/board_name` and `/etc/openwrt_release`
  /// itself, which cost several round trips and put firmware knowledge on the
  /// wrong side. The device already knows what it is; it says so here.
  final String? board;
  final String? release;
  final String? target;

  bool get isCompatible => contractVersion == kAgentContractVersion;

  factory AgentCapabilities.fromJson(Map<String, dynamic> json) {
    final version = json['contract_version'];
    if (version is! int) {
      throw AgentProtocolException(
        'Thiếu hoặc sai kiểu "contract_version" trong phản hồi list.',
      );
    }
    final tools = json['tools'];
    if (tools is! List) {
      throw AgentProtocolException(
        'Thiếu hoặc sai kiểu "tools" trong phản hồi list.',
      );
    }
    return AgentCapabilities(
      contractVersion: version,
      toolNames: tools.whereType<String>().toSet(),
      agentVersion: json['agent_version'] as String?,
      board: json['board'] as String?,
      release: json['release'] as String?,
      target: json['target'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'contract_version': contractVersion,
    'tools': toolNames.toList()..sort(),
    'agent_version': ?agentVersion,
    'board': ?board,
    'release': ?release,
    'target': ?target,
  };
}

/// A change written to the device's staging area but not yet committed.
class StagedChange {
  const StagedChange({
    required this.token,
    required this.diff,
    this.summary,
    this.warning,
  });

  /// Identifies this staging attempt. Commit and revert refer to it so a
  /// concurrent staging cannot be committed by mistake.
  final String token;

  /// The device's own view of what is pending, shown verbatim for approval.
  final String diff;

  final String? summary;
  final String? warning;

  bool get isEmpty => diff.trim().isEmpty;

  factory StagedChange.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw AgentProtocolException('Phản hồi stage thiếu "token".');
    }
    return StagedChange(
      token: token,
      diff: json['diff'] as String? ?? '',
      summary: json['summary'] as String?,
      warning: json['warning'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'token': token,
    'diff': diff,
    if (summary != null) 'summary': summary,
    if (warning != null) 'warning': warning,
  };
}

/// How far a committed change actually got.
///
/// The middle state is the one that matters: `uci commit` can succeed while the
/// service reload fails, leaving the device configured but not behaving as
/// configured. Collapsing that into "done" is what lets an assistant report
/// success for a change that never took effect.
enum CommitVerdict {
  /// Written and confirmed live by a runtime check.
  appliedAndLive,

  /// Written to config, but the runtime check did not confirm it.
  committedNotLive,

  /// Did not apply; the device should be unchanged.
  failed;

  static CommitVerdict parse(String? raw) => switch (raw) {
    'applied_and_live' => CommitVerdict.appliedAndLive,
    'committed_not_live' => CommitVerdict.committedNotLive,
    'failed' => CommitVerdict.failed,
    _ => throw AgentProtocolException('Verdict không hợp lệ: $raw'),
  };

  String get wireName => switch (this) {
    CommitVerdict.appliedAndLive => 'applied_and_live',
    CommitVerdict.committedNotLive => 'committed_not_live',
    CommitVerdict.failed => 'failed',
  };
}

/// One field the agent read back after committing.
class ReadbackField {
  const ReadbackField({
    required this.key,
    required this.expected,
    required this.actual,
  });

  final String key;
  final String? expected;
  final String? actual;

  bool get matches => expected == actual;

  factory ReadbackField.fromJson(String key, Map<String, dynamic> json) =>
      ReadbackField(
        key: key,
        expected: json['expected']?.toString(),
        actual: json['actual']?.toString(),
      );

  Map<String, dynamic> toJson() => {'expected': expected, 'actual': actual};
}

/// Result of committing a staged change, carrying the evidence rather than
/// just an assertion of success.
class CommitOutcome {
  const CommitOutcome({
    required this.verdict,
    this.readback = const [],
    this.runtimeState = const {},
    this.message,
  });

  final CommitVerdict verdict;

  /// Config values re-read from the device and compared with the intent.
  final List<ReadbackField> readback;

  /// Live system state, e.g. whether the radio came back up.
  final Map<String, dynamic> runtimeState;

  final String? message;

  /// Fields whose read-back value did not match what was requested.
  List<ReadbackField> get mismatches =>
      readback.where((f) => !f.matches).toList();

  factory CommitOutcome.fromJson(Map<String, dynamic> json) {
    final rawReadback = json['config_readback'];
    final fields = <ReadbackField>[];
    if (rawReadback is Map<String, dynamic>) {
      for (final entry in rawReadback.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          fields.add(ReadbackField.fromJson(entry.key, value));
        }
      }
    }
    return CommitOutcome(
      verdict: CommitVerdict.parse(json['verdict'] as String?),
      readback: fields,
      runtimeState: json['runtime_state'] is Map<String, dynamic>
          ? json['runtime_state'] as Map<String, dynamic>
          : const {},
      message: json['message'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'verdict': verdict.wireName,
    if (readback.isNotEmpty)
      'config_readback': {for (final f in readback) f.key: f.toJson()},
    if (runtimeState.isNotEmpty) 'runtime_state': runtimeState,
    if (message != null) 'message': message,
  };
}

/// Raised when the agent's reply does not satisfy the contract.
class AgentProtocolException implements Exception {
  AgentProtocolException(this.message, {this.rawResponse});

  final String message;

  /// Truncated raw output, to make a malformed reply diagnosable.
  final String? rawResponse;

  @override
  String toString() => rawResponse == null
      ? message
      : '$message\nPhản hồi thô: $rawResponse';
}

/// Raised when the agent reports a failure of its own.
class AgentErrorException implements Exception {
  AgentErrorException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}

/// The device has no such tool at all.
///
/// Lives here rather than with the other error-code groups in `mcp_client.dart`
/// because both wire protocols raise it — the MCP client from `tools/list`, the
/// staged-write client from its `list` reply — and neither should have to depend
/// on the other to name it.
///
/// Deliberately not folded into `kRouterFaultCodes`, even though both mean "stop
/// calling this tool": a dead ubus may answer on the next turn, a capability the
/// firmware does not have never will, and the model has to tell the user which
/// one it hit. What it must not do is retry with a different argument — no
/// argument can rescue a tool that is not there.
const String kUnsupportedToolCode = 'unsupported_tool';

bool isUnsupportedTool(String code) => code == kUnsupportedToolCode;

/// Builds the request body for [method].
Map<String, dynamic> buildRequest(
  AgentMethod method, {
  String? tool,
  Map<String, dynamic>? args,
  String? token,
}) => {
  'method': method.wireName,
  'tool': ?tool,
  'args': ?args,
  'token': ?token,
};

/// Parses the agent's raw stdout into the response envelope (JSON data)
///
/// Agents run on busybox and can emit warnings before the payload, so parsing
/// starts at the first `{`. Anything that still fails to decode is reported
/// with the raw text attached rather than as a bare type error.
Map<String, dynamic> decodeEnvelope(String stdout) {
  final start = stdout.indexOf('{');
  if (start < 0) {
    throw AgentProtocolException(
      'Agent không trả về JSON.',
      rawResponse: _truncate(stdout),
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(stdout.substring(start));
  } catch (error) {
    throw AgentProtocolException(
      'Không phân tích được JSON từ agent: $error',
      rawResponse: _truncate(stdout),
    );
  }

  if (decoded is! Map<String, dynamic>) {
    throw AgentProtocolException(
      'Agent trả về ${decoded.runtimeType}, mong đợi một object JSON.',
      rawResponse: _truncate(stdout),
    );
  }

  if (decoded['ok'] == false) {
    final error = decoded['error'];
    if (error is Map<String, dynamic>) {
      throw AgentErrorException(
        error['code']?.toString() ?? 'unknown',
        error['message']?.toString() ?? 'Agent báo lỗi không rõ nguyên nhân.',
      );
    }
    throw AgentErrorException('unknown', 'Agent báo lỗi không rõ nguyên nhân.');
  }

  final result = decoded['result'];
  if (result is! Map<String, dynamic>) {
    throw AgentProtocolException(
      'Phản hồi thiếu trường "result".',
      rawResponse: _truncate(stdout),
    );
  }
  return result;
}

String _truncate(String value, [int max = 400]) =>
    value.length <= max ? value : '${value.substring(0, max)}…';
