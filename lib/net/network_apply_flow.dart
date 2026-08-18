/// The small, testable policy around an approved LAN mutation.
///
/// This class deliberately has no SSH, database, UI, or LLM dependency. The
/// caller supplies the two privileged operations, which keeps the rules that
/// prevent an accidental apply directly testable.
class NetworkApplyOutcome {
  const NetworkApplyOutcome({required this.status, required this.message});

  final String status;
  final String message;

  Map<String, String> toModelJson() => {'status': status, 'message': message};
}

typedef ApplyNetworkPlan =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> arguments);

typedef ReconnectAndConfirmHealth =
    Future<bool> Function({
      required String healthToken,
      required int deadlineSeconds,
    });

/// Applies only an approved static plan, then requires reconnect + health
/// confirmation before reporting success. Tokens never appear in its result.
Future<NetworkApplyOutcome> runApprovedNetworkApply({
  required bool applyEnabled,
  required bool approved,
  required String proto,
  required String planToken,
  required ApplyNetworkPlan apply,
  required ReconnectAndConfirmHealth reconnectAndConfirmHealth,
}) async {
  if (!approved) {
    return const NetworkApplyOutcome(
      status: 'cancelled',
      message: 'Người dùng đã hủy, router không thay đổi.',
    );
  }
  if (proto == 'dhcp') {
    return const NetworkApplyOutcome(
      status: 'dhcp_preview_only',
      message:
          'Đổi LAN sang DHCP chưa thể áp dụng tự động vì ứng dụng không biết '
          'địa chỉ mới để kết nối lại và xác nhận an toàn.',
    );
  }
  if (!applyEnabled) {
    return const NetworkApplyOutcome(
      status: 'apply_disabled',
      message: 'Áp dụng thay đổi mạng chưa được bật trong ứng dụng.',
    );
  }

  final applied = await apply({'plan_token': planToken, 'confirmed': true});
  final healthToken = applied['health_token'];
  final deadline = applied['deadline'];
  if (healthToken is! String || healthToken.length != 64 || deadline is! num) {
    return const NetworkApplyOutcome(
      status: 'invalid_apply_response',
      message: 'Agent không trả về dữ liệu xác nhận sức khỏe hợp lệ.',
    );
  }

  final healthy = await reconnectAndConfirmHealth(
    healthToken: healthToken,
    deadlineSeconds: deadline.toInt(),
  );
  return healthy
      ? const NetworkApplyOutcome(
          status: 'confirmed',
          message: 'Đã đổi IP LAN và xác nhận router hoạt động ở địa chỉ mới.',
        )
      : const NetworkApplyOutcome(
          status: 'health_confirmation_failed',
          message:
              'Không thể kết nối lại và xác nhận trước hạn. Router sẽ tự '
              'rollback cấu hình; IP đã lưu trong ứng dụng không thay đổi.',
        );
}
