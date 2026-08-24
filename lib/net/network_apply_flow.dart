/// Kết quả của một lượt áp dụng thay đổi LAN, ở dạng model đọc được.
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

/// Quy tắc nhỏ, dễ test, bao quanh một thay đổi LAN đã được duyệt.
///
/// Chỉ áp dụng kế hoạch tĩnh đã được duyệt, rồi bắt buộc kết nối lại và xác
/// nhận sức khoẻ trước khi báo thành công. Token không bao giờ lọt vào kết quả.
///
/// Cố ý không phụ thuộc SSH, database, UI hay LLM: bên gọi truyền vào hai thao
/// tác đặc quyền, nhờ vậy các quy tắc chặn apply ngoài ý muốn test được trực
/// tiếp.
Future<NetworkApplyOutcome> runApprovedNetworkApply({
  required bool applyEnabled,
  required bool approved,
  required String proto,
  required String planToken,
  required String previewHealthToken,
  required int previewDeadlineSeconds,
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

  // Apply can drop the old SSH connection before a response comes back. The
  // preview already bound these values to the plan, so keep reconnecting with
  // them instead of trusting an apply response that may never arrive.
  await apply({'plan_token': planToken, 'confirmed': true});

  final healthy = await reconnectAndConfirmHealth(
    healthToken: previewHealthToken,
    deadlineSeconds: previewDeadlineSeconds,
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
