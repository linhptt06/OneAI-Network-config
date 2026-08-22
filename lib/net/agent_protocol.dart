/// Shared errors raised while talking to the router's MCP agent.
library;

/// Raised when a router reply does not satisfy the expected protocol.
class AgentProtocolException implements Exception {
  AgentProtocolException(this.message, {this.rawResponse});

  final String message;
  final String? rawResponse;

  @override
  String toString() =>
      rawResponse == null ? message : '$message\nPhản hồi thô: $rawResponse';
}

/// Raised when the router returns a tool-level error.
class AgentErrorException implements Exception {
  AgentErrorException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}

/// The current router does not advertise the requested tool.
const String kUnsupportedToolCode = 'unsupported_tool';

bool isUnsupportedTool(String code) => code == kUnsupportedToolCode;
