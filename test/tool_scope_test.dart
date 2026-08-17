import 'package:chatbot/llm/chat_controller.dart';
import 'package:chatbot/llm/net_tools.dart';
import 'package:chatbot/net/tool_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tool_catalogue.dart';

void main() {
  group('toolsFor narrows the prompt to what can actually run', () {
    test('offers only local tools before anything is connected', () {
      // Read tools here could do nothing but throw "Chưa kết nối tới thiết bị
      // nào", so their schemas would cost context on every turn for a round the
      // model cannot win.
      final offered = toolsFor(realCatalogue(), const {});

      expect(namesOf(offered), {'list_devices', 'connect_device'});
    });

    test('drops read tools the connected device does not declare', () {
      // This router has no wireless section support; wifi_get therefore never
      // reaches the prompt instead of being called and answered with
      // unsupported_tool.
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
      // The trap this function exists to avoid: the router never declares the
      // tools that run on the phone, so filtering the catalogue as a whole
      // would remove the only way to connect — with no way back.
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
      // Same boundary as negotiateTools: a device naming something this build
      // never wrote a description for cannot add a tool to the prompt.
      final offered = toolsFor(realCatalogue(), const {
        'wifi_get',
        'exfiltrate_password',
      });

      expect(namesOf(offered), {'list_devices', 'connect_device', 'wifi_get'});
    });

    test('offers every read tool a fully capable device declares', () {
      final offered = toolsFor(realCatalogue(), kReadToolNames);

      expect(namesOf(offered), namesOf(realCatalogue()));
    });
  });

  group('every tool name the model reads is a tool that exists', () {
    // The invariant that a redaction placeholder broke: it named `get_wifi_info`
    // for months, and a test asserting `contains('get_wifi_info')` guarded the
    // typo instead of the contract. Any string the model reads can drift the same
    // way — the compiler checks none of them — so the check has to ask the
    // catalogue rather than repeat a literal.

    test('the system prompt', () {
      // kSystemPrompt maps questions to tools by name (rules 2-5). Renaming a
      // tool without editing it here would leave the model with instructions to
      // call something that no longer answers.
      expect(
        toolNamesMentionedIn(kSystemPrompt).difference(namesOf(realCatalogue())),
        isEmpty,
      );
    });

    test('tool and parameter descriptions', () {
      // connect_device's parameter says "lấy từ list_devices"; that cross
      // reference is only useful while the name is real.
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
      // Guards the regex itself: a pattern that matched nothing would make both
      // tests above pass no matter how wrong the prose got.
      expect(toolNamesMentionedIn('gọi lại get_wifi_info để đọc'), {
        'get_wifi_info',
      });
      expect(
        toolNamesMentionedIn('gọi lại get_wifi_info').difference(
          namesOf(realCatalogue()),
        ),
        {'get_wifi_info'},
      );
    });
  });

  group('ToolHost reports the device tool names', () {
    test('a fresh host declares nothing', () {
      // What makes the "not connected" case above the real startup state:
      // main.dart builds the catalogue before any device is known.
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
