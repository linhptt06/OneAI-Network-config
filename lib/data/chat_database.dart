import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'chat_models.dart';

/// Kho lưu hội thoại và tin nhắn trên SQLite.
///
/// Đây là nguồn sự thật của lịch sử chat. Engine không nhớ gì giữa các lượt;
/// mỗi yêu cầu phát lại một cửa sổ bản ghi lấy từ đây.
class ChatDatabase {
  ChatDatabase._(this._db);

  final Database _db;

  /// Handle gốc, để các kho khác (hồ sơ thiết bị) dùng chung một file database
  /// thay vì mở thêm file thứ hai.
  Database get raw => _db; 

  static Future<ChatDatabase> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      p.join(dir.path, 'chat.db'),
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            title      TEXT    NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id INTEGER NOT NULL,
            kind            TEXT    NOT NULL,
            content         TEXT    NOT NULL,
            reasoning       TEXT,
            tool_name       TEXT,
            tool_call_id    TEXT,
            tool_arguments  TEXT,
            created_at      INTEGER NOT NULL,
            FOREIGN KEY (conversation_id)
              REFERENCES conversations (id) ON DELETE CASCADE
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_messages_conversation '
          'ON messages (conversation_id, id)',
        );
      },
    );
    return ChatDatabase._(db);
  }

  Future<void> close() => _db.close();

  // ---------------------------------------------------------------- hội thoại

  Future<List<Conversation>> listConversations() async {
    final rows = await _db.query('conversations', orderBy: 'updated_at DESC');
    return rows.map(Conversation.fromRow).toList();
  }

  Future<Conversation> createConversation({String title = 'Cuộc trò chuyện mới'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.insert('conversations', {
      'title': title,
      'created_at': now,
      'updated_at': now,
    });
    return Conversation(
      id: id,
      title: title,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  Future<void> renameConversation(int id, String title) async {
    await _db.update(
      'conversations',
      {'title': title, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteConversation(int id) async {
    await _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _touchConversation(int id) async {
    await _db.update(
      'conversations',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------------------- tin nhắn

  /// Trả về mọi tin nhắn của một hội thoại, cũ trước (dùng cho UI).
  Future<List<StoredMessage>> listMessages(int conversationId) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'id ASC',
    );
    return rows.map(StoredMessage.fromRow).toList();
  }

  /// Trả về [limit] tin nhắn mới nhất, cũ trước (dùng cho cửa sổ prompt).
  ///
  /// Context của engine có hạn nên lượt cũ bị bỏ chứ không gửi. Giữ ở 12 vì
  /// schema các tool mạng đã chiếm một phần context trước khi có chữ nào của
  /// hội thoại; chỉ tăng cùng lúc với `contextSize`.
  Future<List<StoredMessage>> recentMessages(
    int conversationId, {
    int limit = 12,
  }) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map(StoredMessage.fromRow).toList();
  }

  Future<StoredMessage> insertMessage({
    required int conversationId,
    required StoredMessageKind kind,
    required String content,
    String? reasoning,
    String? toolName,
    String? toolCallId,
    String? toolArgumentsJson,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db.insert('messages', {
      'conversation_id': conversationId,
      'kind': kind.name,
      'content': content,
      'reasoning': reasoning,
      'tool_name': toolName,
      'tool_call_id': toolCallId,
      'tool_arguments': toolArgumentsJson,
      'created_at': now,
    });
    await _touchConversation(conversationId);
    return StoredMessage(
      id: id,
      conversationId: conversationId,
      kind: kind,
      content: content,
      reasoning: reasoning,
      toolName: toolName,
      toolCallId: toolCallId,
      toolArgumentsJson: toolArgumentsJson,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  Future<bool> isEmpty(int conversationId) async {
    final rows = await _db.query(
      'messages',
      columns: ['id'],
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    return rows.isEmpty;
  }

}
