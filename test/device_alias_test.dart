import 'package:chatbot/net/device_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveDeviceAlias', () {
    test('matches an alias exactly, ignoring case and surrounding whitespace', () {
      expect(
        resolveDeviceAlias('  ROUTER ONEAI  ', ['router oneai']),
        'router oneai',
      );
    });

    test('accepts a shortened alias when it has one possible device', () {
      expect(
        resolveDeviceAlias('router', ['router oneai']),
        'router oneai',
      );
    });

    test('uses the sole saved device when the model invents a generic alias', () {
      expect(resolveDeviceAlias('router', ['oneai']), 'oneai');
    });

    test('does not guess when a shortened alias matches multiple devices', () {
      expect(
        resolveDeviceAlias('router', ['router oneai', 'router lab']),
        isNull,
      );
    });

    test('does not match an unrelated alias when there are multiple devices', () {
      expect(resolveDeviceAlias('oneai', ['router lab', 'router home']), isNull);
    });
  });
}
