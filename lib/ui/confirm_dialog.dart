import 'package:flutter/material.dart';

import '../net/tool_host.dart';

/// Hỏi người dùng duyệt một thay đổi cấu hình đã staging.
///
/// Phần thân hiển thị nguyên [ConfirmRequest.pendingChanges]: mỗi field một
/// dòng `trước → sau`, dựng từ diff router báo về. Giá trị là của router, chỉ
/// nhãn là của app.
Future<bool> showToolConfirmDialog(
  BuildContext context,
  ConfirmRequest request,
) async {
  final scheme = Theme.of(context).colorScheme;
  final text = Theme.of(context).textTheme;

  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.warning_amber_rounded,
          color: scheme.onErrorContainer,
          size: 24,
        ),
      ),
      title: Text(
        'Áp dụng thay đổi lên ${request.deviceAlias}?',
        textAlign: TextAlign.center,
        style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              request.summary,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Icon(
                  Icons.difference_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Router báo các thay đổi đang chờ',
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: SelectableText(
                request.pendingChanges,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
            if (request.warning != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.report_problem_outlined,
                      size: 17,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        request.warning!,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      actions: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Hủy'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Đồng ý'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  // Hộp thoại bị đóng phải hiểu là từ chối, không bao giờ là đồng ý.
  return approved ?? false;
}
