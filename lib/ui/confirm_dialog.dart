import 'package:flutter/material.dart';

import '../net/tool_host.dart';

/// Asks the user to approve a staged configuration change.
///
/// The body shows the router's verbatim `uci changes` output rather than a
/// sentence composed by the app, so what is displayed is exactly what
/// `uci commit` will apply.
Future<bool> showToolConfirmDialog(
  BuildContext context,
  ConfirmRequest request,
) async {
  final scheme = Theme.of(context).colorScheme;

  final approved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: scheme.error),
      title: Text('Áp dụng thay đổi lên ${request.deviceAlias}?'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(request.summary),
            const SizedBox(height: 16),
            Text(
              'Router báo các thay đổi đang chờ:',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                request.pendingChanges,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            if (request.warning != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.report_problem_outlined,
                      size: 18,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        request.warning!,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onErrorContainer,
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Đồng ý'),
        ),
      ],
    ),
  );

  // A dismissed dialog must read as a refusal, never as approval.
  return approved ?? false;
}
