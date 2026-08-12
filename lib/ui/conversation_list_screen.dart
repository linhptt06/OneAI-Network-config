import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import '../data/chat_database.dart';
import '../data/chat_models.dart';
import '../llm/llm_service.dart';
import '../net/device_profile.dart';
import '../net/tool_host.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chatbot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.router_outlined),
            tooltip: 'Thiết bị OpenWrt',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    DeviceSettingsScreen(store: widget.deviceStore),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _ModelStatusBanner(llm: widget.llm),
          Expanded(
            child: _conversations.isEmpty
                ? const Center(child: Text('Chưa có cuộc trò chuyện nào'))
                : ListView.separated(
                    itemCount: _conversations.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final conversation = _conversations[index];
                      return ListTile(
                        title: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_formatDate(conversation.updatedAt)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await widget.database.deleteConversation(
                              conversation.id,
                            );
                            await _refresh();
                          },
                        ),
                        onTap: () => _open(conversation),
                      );
                    },
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

String _formatDate(DateTime time) =>
    '${time.day.toString().padLeft(2, '0')}/'
    '${time.month.toString().padLeft(2, '0')}/${time.year} '
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

/// Surfaces model download/load state, and offers a retry when it fails.
class _ModelStatusBanner extends StatelessWidget {
  const _ModelStatusBanner({required this.llm});

  final LlmService llm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return switch (llm.status) {
      LlmStatus.ready => const SizedBox.shrink(),
      LlmStatus.error => Material(
        color: scheme.errorContainer,
        child: ListTile(
          leading: Icon(Icons.error_outline, color: scheme.onErrorContainer),
          title: Text(
            'Không tải được model',
            style: TextStyle(color: scheme.onErrorContainer),
          ),
          subtitle: Text(
            llm.errorMessage ?? '',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onErrorContainer),
          ),
          trailing: TextButton(
            onPressed: llm.load,
            child: const Text('Thử lại'),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: value),
        ],
      ),
    );
  }
}
