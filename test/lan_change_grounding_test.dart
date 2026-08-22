import 'package:chatbot/llm/chat_controller.dart';
import 'package:chatbot/llm/llm_service.dart';
import 'package:chatbot/llm/net_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'tool_catalogue.dart';

void main() {
  group('explicit LAN-change detection', () {
    test('recognises an accented or unaccented static LAN request', () {
      expect(
        requiresExplicitLanPreview(
          'Đổi IP LAN thành 10.2.204.212, netmask 255.255.255.0',
        ),
        isTrue,
      );
      expect(
        requiresExplicitLanPreview(
          'doi ip lan thanh 10.2.204.212 netmask 255.255.255.0',
        ),
        isTrue,
      );
    });

    test('defaults a complete IP configuration request to LAN', () {
      expect(
        requiresExplicitLanPreview(
          'cau hinh IP thanh 192.168.89.1 va netmask 255.255.255.0',
        ),
        isTrue,
      );
      expect(
        requiresExplicitLanPreview(
          'cấu hình IP WAN thành 10.2.204.212, netmask 255.255.255.0',
        ),
        isFalse,
      );
    });

    test('extracts the exact app-owned preview arguments', () {
      final command = parseExplicitStaticLanCommand(
        'Đổi IP LAN thành 192.168.89.1, netmask 255.255.255.0',
      );

      expect(command?.ipaddr, '192.168.89.1');
      expect(command?.netmask, '255.255.255.0');
    });

    test('recognises the common subnet mask spelling', () {
      final command = parseExplicitStaticLanCommand(
        'doi IP lan thanh 192.168.89.1, subnet mask 255.255.255.0',
      );

      expect(command?.ipaddr, '192.168.89.1');
      expect(command?.netmask, '255.255.255.0');
    });

    test('does not force a preview while required static data is missing', () {
      expect(requiresExplicitLanPreview('Đổi IP LAN giúp tôi'), isFalse);
      expect(
        requiresExplicitLanPreview('Đổi IP LAN thành 10.2.204.212'),
        isFalse,
      );
    });

    test('asks for clarification instead of inventing a preview', () {
      expect(
        staticLanPreviewClarification(
          'thay doi IP lan thanh 192.168.89.1 va gateway 255.255.255.0',
        ),
        contains('netmask'),
      );
      expect(
        staticLanPreviewClarification(
          'Đổi IP LAN thành 192.168.89.1, netmask 255.255.255.0',
        ),
        isNull,
      );
    });
  });

  group('required preview tool policy', () {
    final offered = toolsFor(realCatalogue(), kLlmRouterToolNames);

    test('offers only preview and requires its call', () {
      final plan = planToolRound(
        offered: offered,
        requiredToolName: 'network_set_preview',
        requiredToolHasBeenCalled: false,
      );

      expect(namesOf(plan.tools!), {'network_set_preview'});
      expect(plan.toolChoice, ToolChoice.required);
    });

    test('returns normal tools after preview has been called', () {
      final plan = planToolRound(
        offered: offered,
        requiredToolName: 'network_set_preview',
        requiredToolHasBeenCalled: true,
      );

      expect(namesOf(plan.tools!), namesOf(offered));
      expect(plan.toolChoice, ToolChoice.auto);
    });

    test('never forces a preview a router did not advertise', () {
      final withoutPreview = offered
          .where((tool) => tool.name != 'network_set_preview')
          .toList();
      final plan = planToolRound(
        offered: withoutPreview,
        requiredToolName: 'network_set_preview',
        requiredToolHasBeenCalled: false,
      );

      expect(namesOf(plan.tools!), namesOf(withoutPreview));
      expect(plan.toolChoice, ToolChoice.auto);
    });
  });

  group('LAN change transcript is grounded in app state', () {
    test('a missing preview cannot be reported as a successful change', () {
      expect(
        lanChangeCompletionText(previewAttempted: false, status: null),
        'Chưa tạo được bản xem trước đổi IP LAN; router chưa thay đổi cấu hình.',
      );
    });

    test('only confirmed health status reports success', () {
      expect(
        lanChangeCompletionText(previewAttempted: true, status: 'confirmed'),
        contains('thành công'),
      );
      expect(
        lanChangeCompletionText(
          previewAttempted: true,
          status: 'health_confirmation_failed',
        ),
        isNot(contains('thành công')),
      );
    });

    test('transport loss after approval does not claim no router change', () {
      final text = lanChangeUnverifiedText();

      expect(text, contains('có thể đã áp dụng IP mới'));
      expect(text, isNot(contains('router chưa thay đổi')));
    });
  });

  group('connection transcript is grounded in app state', () {
    test('keeps a successful connection reply concise', () {
      const result =
          '{"connected":true,"device":"oneai","agent":"router-agent-c",'
          '"agent_version":"0.1.0","supported_tools":["wifi_get",'
          '"network_get"]}';

      expect(
        connectionCompletionText(result),
        'Đã kết nối thành công đến router oneai.',
      );
    });

    test('reports a connection failure without claiming success', () {
      expect(
        connectionCompletionText('{"error":"SSH failed"}'),
        'Không thể kết nối router: SSH failed',
      );
    });
  });

  group('network confirmation boundary', () {
    test('a bare chat confirmation never authorizes apply', () {
      expect(isBareChatConfirmation('xác nhận'), isTrue);
      expect(isBareChatConfirmation('dong y'), isTrue);
      expect(isBareChatConfirmation('xác nhận IP hiện tại'), isFalse);
    });
  });

  group('local capability responses', () {
    test(
      'tool list is answered from discovered capabilities, not the model',
      () {
        expect(isSupportedToolsRequest('cac tools ho tro'), isTrue);
        expect(
          supportedToolsCompletionText(
            deviceAlias: 'oneai',
            toolNames: {
              'network_get',
              'network_list',
              'route_info',
              'traffic_stats',
              'wifi_get',
              'network_set_preview',
            },
          ),
          'Router oneai hỗ trợ 6 tool: network_get, network_list, '
          'network_set_preview, route_info, traffic_stats, wifi_get.',
        );
      },
    );

    test('a wrong-tool complaint is not sent back to the model', () {
      expect(isToolCallComplaint('goi sai tools roi'), isTrue);
      expect(isToolCallComplaint('đọc IP LAN'), isFalse);
    });
  });
}
