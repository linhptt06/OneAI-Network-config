import 'package:chatbot/net/validation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('IPv4 validation', () {
    test('accepts well-formed addresses', () {
      expect(isValidIpv4('192.168.1.1'), isTrue);
      expect(isValidIpv4('0.0.0.0'), isTrue);
      expect(isValidIpv4('255.255.255.255'), isTrue);
    });

    test('rejects malformed addresses', () {
      expect(isValidIpv4('192.168.1'), isFalse);
      expect(isValidIpv4('192.168.1.256'), isFalse);
      expect(isValidIpv4('192.168.1.1.1'), isFalse);
      expect(isValidIpv4('192.168.01.1'), isFalse, reason: 'octal-looking');
      expect(isValidIpv4('abc'), isFalse);
    });

    test('accepts contiguous netmasks only', () {
      expect(isValidIpv4Netmask('255.255.255.0'), isTrue);
      expect(isValidIpv4Netmask('255.255.240.0'), isTrue);
      expect(isValidIpv4Netmask('255.0.0.0'), isTrue);
      expect(isValidIpv4Netmask('255.255.0.255'), isFalse);
      expect(isValidIpv4Netmask('255.255.255.1'), isFalse);
    });
  });

  group('validators reject what would break the router', () {
    test('WPA passphrase length is enforced', () {
      expect(
        () => validateWifiPassword('short', 'psk2'),
        throwsA(isA<UciValidationException>()),
      );
      expect(
        () => validateWifiPassword('a' * 64, 'psk2'),
        throwsA(isA<UciValidationException>()),
      );
      expect(
        () => validateWifiPassword('goodpassword', 'psk2'),
        returnsNormally,
      );
    });

    test('open networks skip the passphrase rule', () {
      expect(() => validateWifiPassword('', 'none'), returnsNormally);
      expect(() => validateWifiPassword('', 'owe'), returnsNormally);
    });

    test('SSID length is enforced', () {
      expect(() => validateSsid(''), throwsA(isA<UciValidationException>()));
      expect(
        () => validateSsid('a' * 33),
        throwsA(isA<UciValidationException>()),
      );
      expect(() => validateSsid('NhaToi_5G'), returnsNormally);
    });

    test('VLAN id range is enforced', () {
      expect(() => validateVlanId(0), throwsA(isA<UciValidationException>()));
      expect(
        () => validateVlanId(4095),
        throwsA(isA<UciValidationException>()),
      );
      expect(() => validateVlanId(10), returnsNormally);
    });
  });

  group('encryption values the grammar constrains the model to', () {
    test('includes the cipher-pinned form vendor images store', () {
      // The MediaTek image in use stores psk2+ccmp; without it in the list the
      // grammar would force the model to downgrade to bare psk2.
      expect(kWifiEncryptionModes, contains('psk2+ccmp'));
      expect(kWifiEncryptionModes, contains('sae'));
    });

    test('WAN protocols cover the three real cases plus none', () {
      expect(kWanProtocols, ['dhcp', 'static', 'pppoe', 'none']);
    });
  });

}
