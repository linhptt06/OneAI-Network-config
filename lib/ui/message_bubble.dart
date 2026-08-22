import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/chat_models.dart';

/// Renders user-facing chat messages and a compact audit trail for tool use.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    return switch (message.kind) {
      StoredMessageKind.user => _Bubble(
        text: message.content,
        alignment: Alignment.centerRight,
        color: Theme.of(context).colorScheme.primaryContainer,
        textColor: Theme.of(context).colorScheme.onPrimaryContainer,
      ),
      StoredMessageKind.assistant => _Bubble(
        text: message.content,
        alignment: Alignment.centerLeft,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        textColor: Theme.of(context).colorScheme.onSurface,
        reasoning: message.reasoning,
      ),
      StoredMessageKind.toolCall => _ToolTile(
        icon: Icons.build_outlined,
        title: 'Gọi công cụ: ${message.toolName}',
        // Arguments can contain implementation details, so only expose a
        // short status here. The returned value remains available below.
        body: 'Đã gửi yêu cầu tới công cụ.',
      ),
      StoredMessageKind.toolResult => _ToolTile(
        icon: Icons.check_circle_outline,
        title: 'Kết quả: ${message.toolName}',
        body: _prettyJson(message.content),
      ),
    };
  }
}

String _prettyJson(String? raw) {
  if (raw == null || raw.isEmpty) return '{}';
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } catch (_) {
    return raw;
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.alignment,
    required this.color,
    required this.textColor,
    this.reasoning,
  });

  final String text;
  final Alignment alignment;
  final Color color;
  final Color textColor;
  final String? reasoning;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reasoning != null && reasoning!.trim().isNotEmpty)
              Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Suy luận',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  children: [
                    Text(
                      reasoning!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            SelectableText(text, style: TextStyle(color: textColor)),
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          leading: Icon(icon, size: 18, color: scheme.primary),
          title: Text(title, style: Theme.of(context).textTheme.labelMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                body,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
