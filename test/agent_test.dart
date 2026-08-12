import 'package:chatbot/net/agent_client.dart';
import 'package:chatbot/net/agent_protocol.dart';
import 'package:chatbot/net/agent_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

/// Wraps [result] in the success envelope the agent is expected to emit.
Map<String, dynamic> ok(Map<String, dynamic> result) => {
  'ok': true,
  'result': result,
};

ToolDefinition _tool(String name) => ToolDefinition(
  name: name,
  description: 'mô tả do ứng dụng sở hữu',
  parameters: [],
  handler: (_) async => {},
);

void main() {
  group('decodeEnvelope', () {
    test('unwraps the result of a successful reply', () {
      final result = decodeEnvelope('{"ok":true,"result":{"a":1}}');
      expect(result, {'a': 1});
    });

    test('skips warning noise printed before the payload', () {
      // busybox utilities happily print to stdout before the real output.
      final result = decodeEnvelope(
        'ash: warning: something\n{"ok":true,"result":{"a":1}}',
      );
      expect(result, {'a': 1});
    });

    test('turns an agent-reported failure into a typed error', () {
      expect(
        () => decodeEnvelope(
          '{"ok":false,"error":{"code":"bad_args","message":"thiếu ssid"}}',
        ),
        throwsA(
          isA<AgentErrorException>()
              .having((e) => e.code, 'code', 'bad_args')
              .having((e) => e.message, 'message', contains('thiếu ssid')),
        ),
      );
    });

    test('rejects output containing no JSON, keeping the raw text', () {
      expect(
        () => decodeEnvelope('sh: netagent: not found'),
        throwsA(
          isA<AgentProtocolException>().having(
            (e) => e.rawResponse,
            'rawResponse',
            contains('not found'),
          ),
        ),
      );
    });

    test('rejects a reply with no result field', () {
      expect(
        () => decodeEnvelope('{"ok":true}'),
        throwsA(isA<AgentProtocolException>()),
      );
    });

    test('rejects a JSON array', () {
      expect(
        () => decodeEnvelope('[1,2,3]'),
        throwsA(isA<AgentProtocolException>()),
      );
    });
  });

  group('AgentCapabilities', () {
    test('parses names and version', () {
      final caps = AgentCapabilities.fromJson({
        'contract_version': 1,
        'tools': ['get_wifi_info', 'set_wifi'],
        'agent_version': 'lua-0.1',
      });
      expect(caps.toolNames, {'get_wifi_info', 'set_wifi'});
      expect(caps.isCompatible, isTrue);
    });

    test('rejects a reply missing the contract version', () {
      expect(
        () => AgentCapabilities.fromJson({'tools': []}),
        throwsA(isA<AgentProtocolException>()),
      );
    });

    test('flags a version this build cannot drive', () {
      final caps = AgentCapabilities.fromJson({
        'contract_version': 99,
        'tools': [],
      });
      expect(caps.isCompatible, isFalse);
    });
  });

  group('CommitOutcome', () {
    test('distinguishes committed-but-not-live from applied', () {
      final outcome = CommitOutcome.fromJson({
        'verdict': 'committed_not_live',
        'config_readback': {
          'wireless.ra0.ssid': {'expected': 'NhaToi', 'actual': 'NhaToi'},
        },
        'runtime_state': {'ra0.up': false},
        'message': 'wifi reload thất bại',
      });

      expect(outcome.verdict, CommitVerdict.committedNotLive);
      // Config matches yet the change is not live: exactly the state that must
      // not be reported to the user as success.
      expect(outcome.mismatches, isEmpty);
      expect(outcome.runtimeState['ra0.up'], isFalse);
    });

    test('surfaces read-back mismatches', () {
      final outcome = CommitOutcome.fromJson({
        'verdict': 'failed',
        'config_readback': {
          'wireless.ra0.ssid': {'expected': 'NhaToi', 'actual': 'oneai'},
        },
      });
      expect(outcome.mismatches.single.key, 'wireless.ra0.ssid');
    });

    test('rejects an unknown verdict rather than guessing', () {
      expect(
        () => CommitOutcome.fromJson({'verdict': 'probably_fine'}),
        throwsA(isA<AgentProtocolException>()),
      );
    });
  });

  group('AgentClient', () {
    test('sends method names on the wire and caches capabilities', () async {
      final transport = FakeAgentTransport(
        (_) => ok({
          'contract_version': 1,
          'tools': ['get_wifi_info'],
        }),
      );
      final client = AgentClient(transport);
      await client.discover();

      expect(transport.requests.single['method'], 'list');
      expect(client.capabilities!.toolNames, {'get_wifi_info'});
    });

    test('refuses to drive an incompatible agent', () async {
      final client = AgentClient(
        FakeAgentTransport((_) => ok({'contract_version': 2, 'tools': []})),
      );
      await expectLater(
        client.discover(),
        throwsA(isA<AgentIncompatibleException>()),
      );
    });

    test('refuses a tool the device never advertised', () async {
      final client = AgentClient(
        FakeAgentTransport(
          (_) => ok({
            'contract_version': 1,
            'tools': ['get_wifi_info'],
          }),
        ),
      );
      await client.discover();

      await expectLater(
        client.stage('set_wan', {}),
        throwsA(
          isA<AgentErrorException>().having(
            (e) => e.code,
            'code',
            'unsupported_tool',
          ),
        ),
      );
    });

    test('requires discovery before staging', () async {
      final client = AgentClient(FakeAgentTransport((_) => ok({})));
      await expectLater(client.stage('set_wifi', {}), throwsStateError);
    });

    test('carries the staging token through commit', () async {
      final transport = FakeAgentTransport((request) {
        return switch (request['method']) {
          'list' => ok({
            'contract_version': 1,
            'tools': ['set_wifi'],
          }),
          'stage' => ok({'token': 'tok-1', 'diff': "wireless.ra0.ssid='X'"}),
          'commit' => ok({'verdict': 'applied_and_live'}),
          _ => {'ok': false, 'error': {'code': 'bad', 'message': 'unexpected'}},
        };
      });
      final client = AgentClient(transport);
      await client.discover();

      final staged = await client.stage('set_wifi', {'ssid': 'X'});
      expect(staged.token, 'tok-1');
      expect(staged.isEmpty, isFalse);

      final outcome = await client.commit(staged);
      expect(outcome.verdict, CommitVerdict.appliedAndLive);
      expect(transport.requests.last['token'], 'tok-1');
    });
  });

  group('capability negotiation keeps descriptions app-owned', () {
    final appTools = [
      _tool('get_wifi_info'),
      _tool('set_wifi'),
      _tool('set_vlan'),
    ];

    test('drops tools the device cannot perform', () {
      // This router reports no VLAN support, so set_vlan never reaches the
      // prompt and stops costing context on every turn.
      final negotiated = negotiateTools(appTools, {'get_wifi_info', 'set_wifi'});
      expect(negotiated.map((t) => t.name), ['get_wifi_info', 'set_wifi']);
    });

    test('ignores names the app does not define', () {
      // A hostile or newer device offering an unknown name must not be able to
      // introduce a tool the app never wrote a description for.
      const offered = {'set_wifi', 'exfiltrate_password'};

      final negotiated = negotiateTools(appTools, offered);
      expect(negotiated.map((t) => t.name), ['set_wifi']);
      expect(unknownToolNames(appTools, offered), {'exfiltrate_password'});
    });

    test('descriptions always come from the app, never the device', () {
      // Whatever the device says a tool does is inert: only a name crosses the
      // boundary, and the description is looked up in the app's own list.
      final negotiated = negotiateTools(appTools, {'set_wifi'});
      expect(negotiated.single.description, 'mô tả do ứng dụng sở hữu');
    });
  });
}
