import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import '../data/chat_database.dart';
import '../data/chat_models.dart';
import '../llm/llm_service.dart';
import '../net/device_profile.dart';
import '../net/tool_host.dart';
import 'app_theme.dart';
import 'chat_screen.dart';
import 'device_settings_screen.dart';

class ConversationListScreen extends StatefulWidget {
  const ConversationListScreen({
    super.key,
    required this.database,
    required this.deviceStore,
    required this.llm,
    required this.tools,
    required this.toolHost,
  });

  final ChatDatabase database;
  final DeviceStore deviceStore;
  final LlmService llm;
  final List<ToolDefinition> tools;
  final ToolHost toolHost;

  @override
  State<ConversationListScreen> createState() => _ConversationListScreenState();
}

class _ConversationListScreenState extends State<ConversationListScreen> {
  List<Conversation> _conversations = [];

  @override
  void initState() {
    super.initState();
    widget.llm.addListener(_onLlmChanged);
    _refresh();
  }

  @override
  void dispose() {
    widget.llm.removeListener(_onLlmChanged);
    super.dispose();
  }

  void _onLlmChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final conversations = await widget.database.listConversations();
    if (mounted) setState(() => _conversations = conversations);
  }

  Future<void> _open(Conversation conversation) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          database: widget.database,
          llm: widget.llm,
          tools: widget.tools,
          toolHost: widget.toolHost,
          deviceStore: widget.deviceStore,
          conversation: conversation,
        ),
      ),
    );
    await _refresh();
  }

  Future<void> _createAndOpen() async {
    final conversation = await widget.database.createConversation();
    await _open(conversation);
  }

  /// Xoá là thao tác không hoàn tác được, nên hỏi lại một lần.
  Future<void> _confirmDelete(Conversation conversation) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá cuộc trò chuyện?'),
        content: Text(
          '“${conversation.title}” sẽ bị xoá vĩnh viễn, không khôi phục được.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.database.deleteConversation(conversation.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chatbot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.router_outlined),
            tooltip: 'Thiết bị OpenWrt',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DeviceSettingsScreen(store: widget.deviceStore),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _ModelStatusBanner(llm: widget.llm),
          Expanded(
            child: _conversations.isEmpty
                ? const EmptyState(
                    icon: Icons.forum_outlined,
                    title: 'Chưa có cuộc trò chuyện nào',
                    message:
                        'Bắt đầu một cuộc trò chuyện để hỏi và cấu hình router '
                        'bằng tiếng Việt.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: _conversations.length,
                    itemBuilder: (context, index) => _ConversationCard(
                      conversation: _conversations[index],
                      onTap: () => _open(_conversations[index]),
                      onDelete: () => _confirmDelete(_conversations[index]),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createAndOpen,
        icon: const Icon(Icons.add),
        label: const Text('Trò chuyện mới'),
      ),
    );
  }
}

class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    required this.conversation,
    required this.onTap,
    required this.onDelete,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    Icons.chat_bubble_outline,
                    size: 18,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conversation.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatDate(conversation.updatedAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Xoá',
                  color: scheme.outline,
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hôm nay và hôm qua hiện giờ; xa hơn thì hiện ngày.
String _formatDate(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(time.year, time.month, time.day);
  final clock =
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  final days = today.difference(that).inDays;
  if (days == 0) return 'Hôm nay $clock';
  if (days == 1) return 'Hôm qua $clock';
  return '${time.day.toString().padLeft(2, '0')}/'
      '${time.month.toString().padLeft(2, '0')}/${time.year} $clock';
}

/// Hiện trạng thái tải/nạp model, và cho thử lại khi lỗi.
class _ModelStatusBanner extends StatelessWidget {
  const _ModelStatusBanner({required this.llm});

  final LlmService llm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return switch (llm.status) {
      LlmStatus.ready => const SizedBox.shrink(),
      LlmStatus.error => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Không tải được model',
                      style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      llm.errorMessage ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: llm.load,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                ),
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      ),
      LlmStatus.downloading => _Progress(
        label: llm.downloadProgress == null
            ? 'Đang tải model…'
            : 'Đang tải model ${(llm.downloadProgress! * 100).toStringAsFixed(0)}%',
        value: llm.downloadProgress,
      ),
      LlmStatus.loading => const _Progress(label: 'Đang nạp model…'),
      LlmStatus.idle => const _Progress(label: 'Đang khởi động…'),
    };
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.label, this.value});

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: value),
            ),
          ],
        ),
      ),
    );
  }
}
