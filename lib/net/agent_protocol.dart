/// Các lỗi dùng chung khi giao tiếp với agent MCP trên router.
library;

/// Ném ra khi phản hồi của router không đúng giao thức.
class AgentProtocolException implements Exception {
  AgentProtocolException(this.message, {this.rawResponse});

  final String message;
  final String? rawResponse;

  @override
  String toString() =>
      rawResponse == null ? message : '$message\nPhản hồi thô: $rawResponse';
}

/// Ném ra khi router trả về lỗi ở mức tool.
class AgentErrorException implements Exception {
  AgentErrorException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}

/// Router hiện tại không khai báo tool được yêu cầu.
const String kUnsupportedToolCode = 'unsupported_tool';

bool isUnsupportedTool(String code) => code == kUnsupportedToolCode;
