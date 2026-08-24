import 'package:chatbot/llm/chat_controller.dart';
import 'package:chatbot/llm/net_tools.dart';
import 'package:chatbot/llm/router_state.dart';
import 'package:chatbot/net/tool_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tool_catalogue.dart';

void main() {
  group('toolsFor narrows the prompt to what can actually run', () {
    test('offers only local tools before anything is connected', () {
      // Read tools here could do nothing but throw "Chưa kết nối tới thiết bị
      // nào", so their schemas would cost context on every turn for a round the
      // model không thể thắng.
      final offered = toolsFor(realCatalogue(), const {});

      expect(namesOf(offered), {'list_devices', 'connect_device'});
    });

    test('drops read tools the connected device does not declare', () {
      // Router này không hỗ trợ section wireless, nên wifi_get không bao giờ
      // vào tới prompt, thay vì bị gọi rồi nhận unsupported_tool.
      final offered = toolsFor(realCatalogue(), const {
        'network_get',
        'route_info',
      });

      expect(namesOf(offered), {
        'list_devices',
        'connect_device',
        'network_get',
        'route_info',
      });
    });

    test('keeps connect_device in both states', () {
      // Cái bẫy mà hàm này sinh ra để tránh: router không bao giờ khai các
      // tool chạy trên điện thoại, nên lọc cả catalogue sẽ mất luôn đường kết
      // nối, và không có đường quay lại.
      for (final declared in [
        const <String>{},
        const {'network_get'},
        kReadToolNames,
      ]) {
        expect(
          namesOf(toolsFor(realCatalogue(), declared)),
          containsAll(['list_devices', 'connect_device']),
          reason: 'thiết bị khai $declared',
        );
      }
    });

    test('ignores names the app has no definition for', () {
      // Cùng ranh giới với negotiateTools: thiết bị khai một cái tên mà bản
      // build này chưa viết mô tả thì không thêm được tool vào prompt.
      final offered = toolsFor(realCatalogue(), const {
        'wifi_get',
        'exfiltrate_password',
      });

      expect(namesOf(offered), {'list_devices', 'connect_device', 'wifi_get'});
    });

    test('never offers apply or health confirmation to the LLM', () {
      final offered = toolsFor(realCatalogue(), const {
        'traffic_stats',
        'network_get',
        'network_list',
        'route_info',
        'wifi_get',
        'network_set_preview',
        'network_set_apply',
        'network_set_health_confirm',
      });

      expect(namesOf(offered), {
        'list_devices',
        'connect_device',
        'traffic_stats',
        'network_get',
        'network_list',
        'route_info',
        'wifi_get',
        'network_set_preview',
      });
    });

    test('offers every read tool a fully capable device declares', () {
      final offered = toolsFor(realCatalogue(), kReadToolNames);

      expect(namesOf(offered), namesOf(realCatalogue()));
      expect(namesOf(offered), contains('network_list'));
    });
  });

  group('every tool name the model reads is a tool that exists', () {
    // Bất biến từng bị phá: một chỗ giữ chỗ gọi nhầm `get_wifi_info` suốt
    // nhiều tháng, và test khẳng định `contains('get_wifi_info')` lại canh
    // đúng cái lỗi chính tả đó. Mọi chuỗi model đọc đều có thể trôi như vậy vì
    // compiler không kiểm chuỗi nào, nên phép kiểm phải hỏi catalogue chứ
    // không lặp lại một literal.

    test('the system prompt', () {
      // kSystemPrompt gọi tool theo tên ở các quy tắc 2, 4 và 6-8. Đổi tên
      // tool mà quên sửa ở đó là để lại cho model chỉ dẫn gọi một thứ không
      // còn trả lời.
      expect(
        toolNamesMentionedIn(
          kSystemPrompt,
        ).difference(namesOf(realCatalogue())),
        isEmpty,
      );
    });

    test('tool and parameter descriptions', () {
      // Tham số của connect_device ghi "lấy từ list_devices"; tham chiếu chéo
      // đó chỉ có ích khi cái tên còn thật.
      final prose = realCatalogue()
          .expand(
            (tool) => [
              tool.description,
              ...tool.parameters.map((p) => p.description ?? ''),
            ],
          )
          .join(' ');

      expect(
        toolNamesMentionedIn(prose).difference(namesOf(realCatalogue())),
        isEmpty,
      );
    });

    test('the check can actually fail', () {
      // Canh chính cái regex: một mẫu không khớp gì sẽ khiến hai test trên
      // luôn xanh dù lời văn có sai đến đâu.
      expect(toolNamesMentionedIn('gọi lại get_wifi_info để đọc'), {
        'get_wifi_info',
      });
      expect(
        toolNamesMentionedIn(
          'gọi lại get_wifi_info',
        ).difference(namesOf(realCatalogue())),
        {'get_wifi_info'},
      );
    });
  });

  group('LAN change safety boundary', () {
    test('offers a preview but never exposes the internal apply operation', () {
      final tools = realCatalogue();
      final preview = tools.singleWhere(
        (tool) => tool.name == 'network_set_preview',
      );

      expect(preview.parameters.map((parameter) => parameter.name), [
        'interface',
        'proto',
        'ipaddr',
        'netmask',
        'gateway',
      ]);
      expect(namesOf(tools), isNot(contains('network_set_apply')));
      expect(kSystemPrompt, contains('network_set_preview'));
      expect(kSystemPrompt, isNot(contains('network_set_apply')));
    });
  });

  test('router state contains aliases and LLM-safe capabilities only', () {
    final state = routerStateFor(
      aliases: const ['oneai'],
      connectedDeviceAlias: 'oneai',
      deviceToolNames: const {
        'traffic_stats',
        'network_get',
        'network_list',
        'route_info',
        'wifi_get',
        'network_set_preview',
        'network_set_apply',
        'network_set_health_confirm',
      },
      networkApplyEnabled: false,
    );

    expect(state, {
      'saved_device_aliases': ['oneai'],
      'connected_device_alias': 'oneai',
      'available_router_tools': [
        'network_get',
        'network_list',
        'network_set_preview',
        'route_info',
        'traffic_stats',
        'wifi_get',
      ],
      'network_apply_enabled': false,
    });
  });

  group('ToolHost reports the device tool names', () {
    test('a fresh host declares nothing', () {
      // Vì sao trường hợp "chưa kết nối" ở trên đúng là trạng thái khởi động:
      // main.dart dựng catalogue trước khi biết thiết bị nào.
      expect(ToolHost().deviceToolNames, isEmpty);
      expect(ToolHost().isConnected, isFalse);
    });

    test('a disconnected host offers no read tools', () async {
      final host = ToolHost();
      await host.disconnect();

      expect(namesOf(toolsFor(realCatalogue(), host.deviceToolNames)), {
        'list_devices',
        'connect_device',
      });
    });
  });
}
