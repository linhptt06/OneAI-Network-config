import 'package:chatbot/llm/net_tools.dart';
import 'package:chatbot/net/agent_protocol.dart';
import 'package:chatbot/net/mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wireless sections a real read tool passes in, so the "here are other
/// names" half of the contract is exercised with the same data the model gets.
const _choices = kWifiSections;

Map<String, dynamic> explain(String code, {List<String>? choices = _choices}) =>
    explainAgentError(AgentErrorException(code, 'router nói gì đó'), choices);

/// Advice that tells the model to stop calling this tool.
final stopsRetrying = allOf(
  contains('Đừng gọi lại'),
  isNot(contains('thử lại')),
);

void main() {
  group('unsupported_tool tells the model to stop', () {
    test('does not get the wrong-parameter advice', () {
      // The bug this pins down: unsupported_tool belonged to neither error group,
      // so it fell through to "thử lại với một tên khác trong valid_values" and
      // sent the model hunting for a section name on a tool that is not there.
      expect(explain(kUnsupportedToolCode)['hint'], stopsRetrying);
    });

    test('says the capability is missing, not that the router is broken', () {
      // Both branches say "stop", but the user has to hear which one: a dead
      // ubus may answer next turn, a missing capability never will.
      final missing = explain(kUnsupportedToolCode)['hint'] as String;
      final broken = explain('backend_unavailable')['hint'] as String;

      expect(missing, isNot(broken));
      expect(missing, contains('không hỗ trợ'));
      expect(broken, contains('router'));
    });

    test('withholds valid_values', () {
      // The values are still valid names, which is exactly why leaving them in
      // is a trap: a list of alternatives beside "đừng gọi lại" reads as an
      // invitation, and data outweighs prose for a small model.
      expect(explain(kUnsupportedToolCode).containsKey('valid_values'), isFalse);
    });
  });

  group('the other branches keep their advice', () {
    test('a router fault stops without blaming the parameters', () {
      for (final code in kRouterFaultCodes) {
        expect(explain(code)['hint'], stopsRetrying, reason: code);
        expect(explain(code)['valid_values'], _choices, reason: code);
      }
    });

    test('an ambiguous failure offers both readings and one retry', () {
      final hint = explain('tool_failed')['hint'] as String;

      expect(hint, contains('MỘT lần'));
      // The router collapses every tool error into this code, so neither
      // reading can be ruled out — saying so beats guessing.
      expect(hint, contains('không tồn tại'));
      expect(hint, contains('trục trặc'));
    });

    test('a parameter error points back at the valid names', () {
      final explained = explain('section_not_found');

      expect(explained['hint'], contains('valid_values'));
      expect(explained['valid_values'], _choices);
    });

    test('a free-form tool still gets advice without a value list', () {
      // traffic_stats has no choices on purpose: OS device names follow the
      // board, not this build.
      final explained = explain('section_not_found', choices: null);

      expect(explained['hint'], isNot(contains('valid_values')));
      expect(explained.containsKey('valid_values'), isFalse);
    });
  });

  group('every code lands in exactly one branch', () {
    test('unsupported_tool is not also a router fault or ambiguous', () {
      // Overlap would make the branch order silently decide the advice.
      expect(isRouterFault(kUnsupportedToolCode), isFalse);
      expect(isAmbiguousFailure(kUnsupportedToolCode), isFalse);
    });

    test('the router-fault and ambiguous groups are disjoint', () {
      expect(kRouterFaultCodes.intersection(kAmbiguousFailureCodes), isEmpty);
    });
  });
}
