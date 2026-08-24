import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import '../data/chat_database.dart';
import '../data/chat_models.dart';
import '../llm/chat_controller.dart';
import '../llm/llm_service.dart';
import '../net/device_profile.dart';
import '../net/tool_host.dart';
import 'app_theme.dart';
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
    // Model có thể còn đang nạp lúc mở màn hình; mở lại ô nhập ngay khi sẵn
    // sàng.
    widget.llm.addListener(_onLlmChanged);

    // `network_set_preview` gọi hàm này ngay trong handler, sau khi staging
    // thay đổi và hỏi router những gì đang chờ ghi.
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
      // Kiểm lại lần nữa ở đây: thân hàm chạy trễ một frame, và rời màn hình
      // giữa lúc kết quả tool đang chảy về sẽ dispose _scroll ở khoảng giữa.
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
    // Rời màn hình không được để lại callback cũ có thể duyệt một thay đổi
    // khi không có hộp thoại nào hiện ra.
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

    // Một ô cuối cho văn bản đang chảy về, một ô cho nhật ký tool.
    final extra = (streaming.isNotEmpty ? 1 : 0) + (toolLog.isNotEmpty ? 1 : 0);
    final enabled = widget.llm.isReady && !_controller.isGenerating;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.conversation.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            _ConnectionLine(toolHost: widget.toolHost),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty && extra == 0
                ? _ChatEmptyState(
                    onPick: (text) {
                      _input.text = text;
                      _input.selection = TextSelection.collapsed(
                        offset: text.length,
                      );
                    },
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 16),
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
          if (_controller.isGenerating && streaming.isEmpty && toolLog.isEmpty)
            const _ThinkingRow(),
          _Composer(
            controller: _input,
            enabled: enabled,
            busy: _controller.isGenerating,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

/// Dòng phụ dưới tiêu đề: router nào đang kết nối, hoặc chưa có router nào.
class _ConnectionLine extends StatelessWidget {
  const _ConnectionLine({required this.toolHost});

  final ToolHost toolHost;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connected = toolHost.isConnected;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: connected ? scheme.primary : scheme.outline,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          connected ? toolHost.deviceAlias : 'Chưa kết nối router',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }
}

/// Màn hình chat rỗng: vài câu mẫu để bấm vào là điền sẵn vào ô nhập.
class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState({required this.onPick});

  final ValueChanged<String> onPick;

  static const _suggestions = <(IconData, String)>[
    (Icons.dns_outlined, 'Có những router nào đã lưu?'),
    (Icons.lan_outlined, 'IP LAN của router là gì?'),
    (Icons.wifi_outlined, 'Tên WiFi là gì?'),
    (Icons.route_outlined, 'Router đang ra Internet bằng đường nào?'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      children: [
        Center(
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.router_outlined,
              size: 32,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Hỏi gì về router của bạn?',
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          'Nhắn bằng tiếng Việt bình thường. Mọi thay đổi cấu hình đều hỏi bạn '
          'xác nhận trước khi ghi.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 28),
        for (final (icon, text) in _suggestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              child: InkWell(
                onTap: () => onPick(text),
                borderRadius: BorderRadius.circular(AppTheme.radius),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          text,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      Icon(
                        Icons.north_west,
                        size: 15,
                        color: scheme.outline,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const r = Radius.circular(AppTheme.radiusLarge);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 14),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.80,
          ),
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
          decoration: const BoxDecoration(
            borderRadius: BorderRadius.only(
              topLeft: r,
              topRight: r,
              bottomLeft: Radius.circular(6),
              bottomRight: r,
            ),
          ).copyWith(color: scheme.surfaceContainerHigh),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              height: 1.42,
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Ba chấm nhấp nháy khi model đang nghĩ mà chưa có chữ nào chảy về.
class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow();

  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Row(
              children: List.generate(3, (i) {
                final t = (_pulse.value * 3 - i).clamp(0.0, 1.0);
                final wave = 1 - (2 * t - 1).abs();
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Opacity(
                    opacity: 0.35 + wave * 0.65,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Đang trả lời…',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolActivity extends StatelessWidget {
  const _ToolActivity({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.bolt, size: 13, color: scheme.tertiary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      entry,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
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
    required this.busy,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: enabled
                        ? 'Nhắn tin…'
                        : busy
                        ? 'Đang trả lời…'
                        : 'Đang tải model…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 13,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppTheme.radiusLarge,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppTheme.radiusLarge,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppTheme.radiusLarge,
                      ),
                      borderSide: BorderSide(color: scheme.primary, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                height: 46,
                child: busy
                    ? Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: scheme.primary,
                          ),
                        ),
                      )
                    : IconButton.filled(
                        onPressed: enabled ? onSend : null,
                        icon: const Icon(Icons.arrow_upward, size: 20),
                        style: IconButton.styleFrom(
                          shape: const CircleBorder(),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
