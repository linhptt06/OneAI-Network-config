import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import '../data/chat_database.dart';
import '../data/chat_models.dart';
import '../llm/chat_controller.dart';
import '../llm/llm_service.dart';
import '../net/device_profile.dart';
import '../net/tool_host.dart';
import 'confirm_dialog.dart';
import 'message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.database,
    required this.llm,
    required this.tools,
    required this.toolHost,
    required this.deviceStore,
    required this.conversation,
  });

  final ChatDatabase database;
  final LlmService llm;
  final List<ToolDefinition> tools;
  final ToolHost toolHost;
  final DeviceStore deviceStore;
  final Conversation conversation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _controller;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller = ChatController(
      database: widget.database,
      llm: widget.llm,
      tools: widget.tools,
      toolHost: widget.toolHost,
      deviceStore: widget.deviceStore,
      conversationId: widget.conversation.id,
    )..addListener(_onControllerChanged);
    _controller.loadHistory();
    // The model may still be loading when this screen opens; re-enable the
    // composer as soon as it becomes ready.
    widget.llm.addListener(_onLlmChanged);

    // Write tools call this from inside their handler, after staging the
    // change and asking the router what is pending.
    widget.toolHost.confirm = (request) async {
      if (!mounted) return false;
      return showToolConfirmDialog(context, request);
    };
  }

  void _onLlmChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Checked again here, not just above: this body runs a frame later, and
      // leaving the screen while a tool result is streaming in disposes _scroll
      // in between.
      if (!mounted) return;
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    // Leaving this screen must not leave a stale callback that could approve
    // a change with no dialog on screen.
    widget.toolHost.confirm = (_) async => false;
    widget.llm.removeListener(_onLlmChanged);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await _controller.send(text);
    final error = _controller.turnError;
    if (error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Lỗi: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = _controller.messages;
    final streaming = _controller.streamingText;
    final toolLog = _controller.activeToolLog;

    // One trailing slot for the in-flight assistant text, one for tool activity.
    final extra = (streaming.isNotEmpty ? 1 : 0) + (toolLog.isNotEmpty ? 1 : 0);

    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.title)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: messages.length + extra,
              itemBuilder: (context, index) {
                if (index < messages.length) {
                  return MessageBubble(message: messages[index]);
                }
                final offset = index - messages.length;
                if (toolLog.isNotEmpty && offset == 0) {
                  return _ToolActivity(entries: toolLog);
                }
                return _StreamingBubble(text: streaming);
              },
            ),
          ),
          if (_controller.isGenerating) const LinearProgressIndicator(),
          _Composer(
            controller: _input,
            enabled: widget.llm.isReady && !_controller.isGenerating,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(text),
      ),
    );
  }
}

class _ToolActivity extends StatelessWidget {
  const _ToolActivity({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in entries)
            Row(
              children: [
                const Icon(Icons.bolt, size: 14),
                const SizedBox(width: 6),
                Text(entry, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => enabled ? onSend() : null,
                decoration: InputDecoration(
                  hintText: enabled ? 'Nhắn tin…' : 'Đang tải model…',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
