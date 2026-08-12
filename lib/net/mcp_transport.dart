import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'agent_protocol.dart';

/// Carries JSON-RPC requests to the MCP server running on the router.
///
/// [send] takes a list rather than a single request because the server reads
/// stdin in a loop: several requests ride one SSH exec channel and come back as
/// one reply per line, in order. Opening a channel per request costs a round
/// trip the router can ill afford.
///
/// An interface rather than a concrete class so the client can be driven by a
/// scripted fake in tests, and so a future ubus transport can be dropped in
/// without touching the client.
abstract class McpTransport {
  Future<List<Map<String, dynamic>>> send(List<Map<String, dynamic>> requests);
}

/// Runs `mcp_stdio_server` over the existing SSH connection.
///
/// Nothing user- or model-supplied reaches the command line: the executable
/// path is a constant and every parameter travels inside the JSON body on
/// stdin, so quoting bugs cannot become command injection.
class SshMcpTransport implements McpTransport {
  SshMcpTransport(
    this._client, {
    this.serverPath = '/usr/libexec/router-agent/mcp_stdio_server',
    this.timeout = const Duration(seconds: 30),
  });

  final SSHClient _client;

  /// Where `make install` puts the server. The agent repo installs every tool
  /// under `/usr/libexec/router-agent/`.
  final String serverPath;

  final Duration timeout;

  @override
  Future<List<Map<String, dynamic>>> send(
    List<Map<String, dynamic>> requests,
  ) async {
    if (requests.isEmpty) return const [];

    final session = await _client.execute(serverPath);

    final stdoutBytes = BytesBuilder();
    final stderrBytes = BytesBuilder();
    final collecting = Future.wait([
      session.stdout.forEach(stdoutBytes.add),
      session.stderr.forEach(stderrBytes.add),
    ]);

    // The server's read loop rejects any line that does not end in `\n`, so the
    // terminator is part of the contract rather than cosmetic.
    final payload = StringBuffer();
    for (final request in requests) {
      payload.write(jsonEncode(request));
      payload.write('\n');
    }
    session.stdin.add(Uint8List.fromList(utf8.encode(payload.toString())));
    // The server reads until EOF, so stdin must be closed or both sides wait
    // for each other until the timeout fires.
    await session.stdin.close();

    try {
      await collecting.timeout(timeout);
      await session.waitForExit(timeout: timeout);
    } on TimeoutException {
      session.close();
      throw AgentProtocolException(
        'Agent không phản hồi sau ${timeout.inSeconds}s.',
      );
    }

    final stdout = utf8.decode(stdoutBytes.takeBytes(), allowMalformed: true);
    final stderr = utf8.decode(stderrBytes.takeBytes(), allowMalformed: true);

    if (stdout.trim().isEmpty) {
      // A missing server surfaces here as empty stdout plus a shell error,
      // which is worth naming explicitly: it is the expected state before the
      // agent has been installed.
      throw AgentProtocolException(
        stderr.contains('not found')
            ? 'Chưa cài agent trên thiết bị ($serverPath).'
            : 'Agent không trả về gì (exit ${session.exitCode}).',
        rawResponse: stderr.isEmpty ? null : stderr,
      );
    }

    return decodeJsonRpcLines(stdout, expected: requests.length);
  }
}

/// Splits the server's stdout into one decoded reply per line.
///
/// Lines that are not JSON objects are skipped rather than fatal: a login
/// banner or a busybox warning ahead of the payload is noise, not a protocol
/// violation. Too few replies is fatal, because the caller pairs replies with
/// requests by position.
List<Map<String, dynamic>> decodeJsonRpcLines(
  String stdout, {
  required int expected,
}) {
  final replies = <Map<String, dynamic>>[];

  for (final line in const LineSplitter().convert(stdout)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      continue;
    }
    if (decoded is Map<String, dynamic>) replies.add(decoded);
  }

  if (replies.length < expected) {
    throw AgentProtocolException(
      'Agent trả về ${replies.length} phản hồi, mong đợi $expected.',
      rawResponse: _truncate(stdout),
    );
  }
  return replies;
}

String _truncate(String value, [int max = 400]) =>
    value.length <= max ? value : '${value.substring(0, max)}…';

/// In-memory transport for tests, and for exercising the client without a
/// router.
class FakeMcpTransport implements McpTransport {
  FakeMcpTransport(this._handler);

  /// Receives one request and returns the whole JSON-RPC envelope, so tests can
  /// produce protocol errors and malformed replies as easily as successes.
  final Map<String, dynamic> Function(Map<String, dynamic> request) _handler;

  /// Every request seen, in order, for assertions.
  final List<Map<String, dynamic>> requests = [];

  @override
  Future<List<Map<String, dynamic>>> send(
    List<Map<String, dynamic>> batch,
  ) async {
    requests.addAll(batch);
    return batch.map(_handler).toList();
  }
}
