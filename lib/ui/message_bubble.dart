import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/chat_models.dart';
import 'app_theme.dart';

/// Vẽ tin nhắn chat và một dấu vết gọn cho hoạt động của tool.
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return switch (message.kind) {
      StoredMessageKind.user => _Bubble(
        text: message.content,
        isUser: true,
        color: scheme.primary,
        textColor: scheme.onPrimary,
        time: message.createdAt,
      ),
      StoredMessageKind.assistant => _Bubble(
        text: message.content,
        isUser: false,
        color: scheme.surfaceContainerHigh,
        textColor: scheme.onSurface,
        reasoning: message.reasoning,
        time: message.createdAt,
      ),
      StoredMessageKind.toolCall => _ToolTile(
        icon: Icons.build_outlined,
        title: 'Gọi công cụ: ${message.toolName}',
        // Tham số có thể lộ chi tiết cài đặt, nên ở đây chỉ hiện trạng thái
        // ngắn. Giá trị trả về vẫn xem được bên dưới.
        body: 'Đã gửi yêu cầu tới công cụ.',
        accent: scheme.tertiary,
        monospace: false,
      ),
      StoredMessageKind.toolResult => _ToolTile(
        icon: Icons.check_circle_outline,
        title: 'Kết quả: ${message.toolName}',
        body: _prettyJson(message.content),
        accent: scheme.primary,
        monospace: true,
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

String _formatTime(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.isUser,
    required this.color,
    required this.textColor,
    required this.time,
    this.reasoning,
  });

  final String text;
  final bool isUser;
  final Color color;
  final Color textColor;
  final DateTime time;
  final String? reasoning;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(AppTheme.radiusLarge);
    const tight = Radius.circular(6);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 14),
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.80,
            ),
            padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
            decoration: BoxDecoration(
              color: color,
              // Góc nhọn ở phía người nói, tạo cảm giác bong bóng có đuôi.
              borderRadius: BorderRadius.only(
                topLeft: r,
                topRight: r,
                bottomLeft: isUser ? r : tight,
                bottomRight: isUser ? tight : r,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (reasoning != null && reasoning!.trim().isNotEmpty)
                  _ReasoningSection(reasoning: reasoning!),
                SelectableText(
                  text,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 15,
                    height: 1.42,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
            child: Text(
              _formatTime(time),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Phần suy luận của model, mặc định thu gọn để không lấn câu trả lời.
class _ReasoningSection extends StatefulWidget {
  const _ReasoningSection({required this.reasoning});

  final String reasoning;

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Text(
                  'Suy luận',
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, top: 2),
            child: Text(
              widget.reasoning,
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        if (!_open) const SizedBox(height: 6),
      ],
    );
  }
}

/// Dòng ghi nhận một lần gọi tool: gọn khi đóng, xem được đầy đủ khi mở.
class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
    required this.monospace,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color accent;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 14),
      // Material chứ không phải Container: ExpansionTile vẽ nền và hiệu ứng
      // chạm lên Material gần nhất, một DecoratedBox có màu sẽ che mất chúng.
      child: Material(
        color: scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            dense: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: accent),
            ),
            title: Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      body,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: monospace ? 'monospace' : null,
                        height: 1.4,
                      ),
                    ),
                    if (monospace) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _CopyButton(text: body),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () {
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã sao chép kết quả')),
        );
      },
      icon: const Icon(Icons.copy_all_outlined, size: 14),
      label: const Text('Sao chép'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
