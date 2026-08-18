import 'package:flutter/material.dart';

import '../data/chat_models.dart';

/// Renders user-facing chat messages.
///
/// Tool calls are retained in SQLite to reconstruct the next model turn, but
/// they are application internals. Showing their JSON or names would make the
/// user decipher implementation details instead of the assistant's answer.
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
      StoredMessageKind.toolCall ||
      StoredMessageKind.toolResult => const SizedBox.shrink(),
    };
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
