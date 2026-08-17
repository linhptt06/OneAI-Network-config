import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import 'data/chat_database.dart';
import 'llm/llm_service.dart';
import 'llm/net_tools.dart';
import 'net/device_profile.dart';
import 'net/tool_host.dart';
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

  /// Holds the live SSH session and the confirmation callback. Built once
  /// here so the session survives navigation between screens.
  final _toolHost = ToolHost();

  /// The full tool catalogue — every tool this build can execute.
  ///
  /// Not the list the model sees: `toolsFor` narrows this per round to the tools
  /// the current connection can actually serve, so nothing is built here that
  /// depends on which device is connected.
  ///
  /// Keep this list short anyway. A 1.5B model degrades as it grows: with four
  /// extra demo tools present it began narrating intent ("đang kiểm tra…")
  /// instead of emitting a call, because the schemas crowded the context window.
  late final List<ToolDefinition> _tools = buildNetworkTools(
    widget.deviceStore,
    _toolHost,
  );

  @override
  void initState() {
    super.initState();
    // Not awaited: the UI renders immediately and the status banner reports
    // download/load progress as it happens.
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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
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
