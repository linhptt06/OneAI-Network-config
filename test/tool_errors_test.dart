import 'package:chatbot/llm/net_tools.dart';
import 'package:chatbot/net/agent_protocol.dart';
import 'package:chatbot/net/mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Đúng danh sách section mà một tool đọc thật truyền vào, để nửa "đây là các
/// tên khác" của hợp đồng được kiểm bằng chính dữ liệu model nhận.
const _choices = kWifiSections;

Map<String, dynamic> explain(String code, {List<String>? choices = _choices}) =>
    explainAgentError(AgentErrorException(code, 'router nói gì đó'), choices);

/// Lời khuyên bảo model ngừng gọi tool này.
final stopsRetrying = allOf(
  contains('Đừng gọi lại'),
  isNot(contains('thử lại')),
);

void main() {
  group('unsupported_tool tells the model to stop', () {
    test('does not get the wrong-parameter advice', () {
      // Lỗi mà test này ghim lại: unsupported_tool không thuộc nhóm lỗi nào,
      // so it fell through to "thử lại với một tên khác trong valid_values" and
      // khiến model đi tìm tên section cho một tool không tồn tại.
      expect(explain(kUnsupportedToolCode)['hint'], stopsRetrying);
    });

    test('says the capability is missing, not that the router is broken', () {
      // Cả hai nhánh đều nói "dừng", nhưng người dùng cần biết là nhánh nào:
      // ubus chết có thể sống lại, capability thiếu thì không bao giờ.
      final missing = explain(kUnsupportedToolCode)['hint'] as String;
      final broken = explain('backend_unavailable')['hint'] as String;

      expect(missing, isNot(broken));
      expect(missing, contains('không hỗ trợ'));
      expect(broken, contains('router'));
    });

    test('withholds valid_values', () {
      // Các giá trị vẫn là tên hợp lệ, và đó đúng là lý do để chúng lại
      // is a trap: a list of alternatives beside "đừng gọi lại" reads as an
      // thành lời mời, mà với model nhỏ thì dữ liệu thắng lời văn.
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
      // Router gộp mọi lỗi tool vào mã này nên không loại trừ được cách hiểu
      // nào — nói thẳng là không rõ vẫn hơn đoán.
      expect(hint, contains('không tồn tại'));
      expect(hint, contains('trục trặc'));
    });

    test('a parameter error points back at the valid names', () {
      final explained = explain('section_not_found');

      expect(explained['hint'], contains('valid_values'));
      expect(explained['valid_values'], _choices);
    });

    test('a free-form tool still gets advice without a value list', () {
      // traffic_stats cố ý không có danh sách chọn: tên cổng phụ thuộc board
      // chứ không phụ thuộc bản build này.
      final explained = explain('section_not_found', choices: null);

      expect(explained['hint'], isNot(contains('valid_values')));
      expect(explained.containsKey('valid_values'), isFalse);
    });
  });

  group('every code lands in exactly one branch', () {
    test('unsupported_tool is not also a router fault or ambiguous', () {
      // Trùng nhóm thì thứ tự nhánh sẽ âm thầm quyết định lời khuyên.
      expect(isRouterFault(kUnsupportedToolCode), isFalse);
      expect(isAmbiguousFailure(kUnsupportedToolCode), isFalse);
    });

    test('the router-fault and ambiguous groups are disjoint', () {
      expect(kRouterFaultCodes.intersection(kAmbiguousFailureCodes), isEmpty);
    });
  });
}
