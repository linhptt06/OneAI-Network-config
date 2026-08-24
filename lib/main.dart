import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import 'data/chat_database.dart';
import 'llm/llm_service.dart';
import 'llm/net_tools.dart';
import 'net/device_profile.dart';
import 'net/tool_host.dart';
import 'ui/app_theme.dart';
import 'ui/conversation_list_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await ChatDatabase.open();
  final deviceStore = DeviceStore(database.raw);
  await deviceStore.ensureTable();
  runApp(ChatbotApp(database: database, deviceStore: deviceStore));
}

class ChatbotApp extends StatefulWidget {
  const ChatbotApp({
    super.key,
    required this.database,
    required this.deviceStore,
  });

  final ChatDatabase database;
  final DeviceStore deviceStore;

  @override
  State<ChatbotApp> createState() => _ChatbotAppState();
}

class _ChatbotAppState extends State<ChatbotApp> {
  final _llm = LlmService();

  /// Giữ phiên SSH đang sống và callback xác nhận. Dựng một lần ở đây để
  /// phiên không mất khi chuyển màn hình.
  // Agent trên router có rollback guard hết hạn và bước health-confirm. LLM
  // vẫn không bật được cờ này: chỉ tới được sau khi người dùng bấm đồng ý.
  final _toolHost = ToolHost(networkApplyEnabled: true);

  /// Toàn bộ catalogue — mọi tool bản build này chạy được.
  ///
  /// Không phải danh sách model nhìn thấy: `toolsFor` lọc lại theo từng vòng
  /// dựa trên thiết bị đang kết nối.
  ///
  /// Vẫn nên giữ danh sách ngắn. Thêm bốn tool demo là model bắt đầu kể lể
  /// ("đang kiểm tra…") thay vì gọi tool, vì schema chiếm hết context.
  late final List<ToolDefinition> _tools = buildNetworkTools(
    widget.deviceStore,
    _toolHost,
  );

  @override
  void initState() {
    super.initState();
    // Không await: UI hiện ngay, banner trạng thái báo tiến độ tải/nạp.
    _llm.load();
  }

  @override
  void dispose() {
    _toolHost.disconnect();
    _llm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chatbot',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: ConversationListScreen(
        database: widget.database,
        deviceStore: widget.deviceStore,
        llm: _llm,
        tools: _tools,
        toolHost: _toolHost,
      ),
    );
  }
}
