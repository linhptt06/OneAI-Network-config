import 'package:chatbot/net/network_apply_flow.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final expectedPlanToken = List.filled(64, 'a').join();
  final expectedHealthToken = List.filled(64, 'b').join();

  group('runApprovedNetworkApply', () {
    test('cancel never calls apply', () async {
      var applyCalls = 0;
      var healthCalls = 0;

      final result = await runApprovedNetworkApply(
        applyEnabled: true,
        approved: false,
        proto: 'static',
        planToken: expectedPlanToken,
        apply: (_) async {
          applyCalls++;
          return {};
        },
        reconnectAndConfirmHealth:
            ({required healthToken, required deadlineSeconds}) async {
              healthCalls++;
              return true;
            },
      );

      expect(result.status, 'cancelled');
      expect(applyCalls, 0);
      expect(healthCalls, 0);
    });

    test('DHCP stays preview-only and never calls apply', () async {
      var applyCalls = 0;

      final result = await runApprovedNetworkApply(
        applyEnabled: true,
        approved: true,
        proto: 'dhcp',
        planToken: expectedPlanToken,
        apply: (_) async {
          applyCalls++;
          return {};
        },
        reconnectAndConfirmHealth:
            ({required healthToken, required deadlineSeconds}) async => true,
      );

      expect(result.status, 'dhcp_preview_only');
      expect(applyCalls, 0);
    });

    test('approved static change applies once then confirms health', () async {
      var applyCalls = 0;
      var healthCalls = 0;

      final result = await runApprovedNetworkApply(
        applyEnabled: true,
        approved: true,
        proto: 'static',
        planToken: expectedPlanToken,
        apply: (arguments) async {
          applyCalls++;
          expect(arguments, {
            'plan_token': expectedPlanToken,
            'confirmed': true,
          });
          return {'health_token': expectedHealthToken, 'deadline': 2000000000};
        },
        reconnectAndConfirmHealth:
            ({required healthToken, required deadlineSeconds}) async {
              healthCalls++;
              expect(healthToken, expectedHealthToken);
              expect(deadlineSeconds, 2000000000);
              return true;
            },
      );

      expect(result.status, 'confirmed');
      expect(applyCalls, 1);
      expect(healthCalls, 1);
      expect(
        result.toModelJson().toString(),
        isNot(contains(expectedHealthToken)),
      );
      expect(
        result.toModelJson().toString(),
        isNot(contains(expectedPlanToken)),
      );
    });

    test('reconnect or health-confirm failure never reports success', () async {
      var applyCalls = 0;

      final result = await runApprovedNetworkApply(
        applyEnabled: true,
        approved: true,
        proto: 'static',
        planToken: expectedPlanToken,
        apply: (_) async {
          applyCalls++;
          return {'health_token': expectedHealthToken, 'deadline': 2000000000};
        },
        reconnectAndConfirmHealth:
            ({required healthToken, required deadlineSeconds}) async => false,
      );

      expect(applyCalls, 1);
      expect(result.status, 'health_confirmation_failed');
      expect(result.message, contains('rollback'));
    });

    test('disabled apply does not call the router', () async {
      var applyCalls = 0;

      final result = await runApprovedNetworkApply(
        applyEnabled: false,
        approved: true,
        proto: 'static',
        planToken: expectedPlanToken,
        apply: (_) async {
          applyCalls++;
          return {};
        },
        reconnectAndConfirmHealth:
            ({required healthToken, required deadlineSeconds}) async => true,
      );

      expect(result.status, 'apply_disabled');
      expect(applyCalls, 0);
    });
  });
}
