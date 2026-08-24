import 'package:chatbot/llm/net_tools.dart';
import 'package:chatbot/net/device_profile.dart';
import 'package:chatbot/net/tool_host.dart';
import 'package:llamadart/llamadart.dart';
import 'package:sqflite/sqflite.dart';

/// Một database từ chối mọi lời gọi.
///
/// `buildNetworkTools` chỉ *mô tả* tool: store và host bị handler bắt lại, dựng
/// định nghĩa không chạy cái nào cả. Cắm vào một database luôn ném lỗi giữ cho
/// giả định đó trung thực — nếu có định nghĩa nào bắt đầu truy vấn lúc dựng,
/// test sẽ hỏng to thay vì âm thầm dựa vào một stub biết trả lời.
class _UnusableDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Dựng định nghĩa tool không được chạm database.',
  );
}

/// Đúng catalogue app đưa ra, dựng được mà không cần plugin nền tảng nào.
///
/// Test kiểm tên, giá trị mặc định hay mô tả phải đi qua đây thay vì một danh
/// sách viết tay: danh sách giả chỉ khớp với danh sách giả, trong khi lỗi cần
/// chặn chính là danh sách thật trôi khỏi các chuỗi gọi tên nó.
List<ToolDefinition> realCatalogue() =>
    buildNetworkTools(DeviceStore(_UnusableDatabase()), ToolHost());

Set<String> namesOf(Iterable<ToolDefinition> tools) =>
    tools.map((t) => t.name).toSet();

/// Các từ snake_case trong [text] — dạng của một tên tool khi nó xuất hiện
/// giữa câu tiếng Việt, vốn không dùng dấu gạch dưới.
Set<String> toolNamesMentionedIn(String text) =>
    RegExp(r'\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b')
        .allMatches(text)
        .map((match) => match[0]!)
        .toSet();
