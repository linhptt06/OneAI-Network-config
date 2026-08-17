import 'package:chatbot/llm/net_tools.dart';
import 'package:chatbot/net/device_profile.dart';
import 'package:chatbot/net/tool_host.dart';
import 'package:llamadart/llamadart.dart';
import 'package:sqflite/sqflite.dart';

/// A database that refuses every call.
///
/// `buildNetworkTools` only *describes* tools: the store and the host are
/// captured by handlers, and building a definition runs none of them. Standing
/// in a database that throws keeps that assumption honest — if a definition ever
/// starts querying at build time, these tests fail loudly instead of quietly
/// depending on a stub that answers.
class _UnusableDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Dựng định nghĩa tool không được chạm database.',
  );
}

/// The catalogue the app actually offers, built without any platform plugin.
///
/// Tests that check names, defaults or descriptions must go through this rather
/// than a hand-written list: a fake catalogue can agree with a fake, while the
/// bug these invariants guard against is precisely the real list drifting away
/// from the strings that name it.
List<ToolDefinition> realCatalogue() =>
    buildNetworkTools(DeviceStore(_UnusableDatabase()), ToolHost());

Set<String> namesOf(Iterable<ToolDefinition> tools) =>
    tools.map((t) => t.name).toSet();

/// Snake_case words in [text] — how a tool name looks when it appears inside
/// Vietnamese prose, which uses no underscores.
Set<String> toolNamesMentionedIn(String text) =>
    RegExp(r'\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b')
        .allMatches(text)
        .map((match) => match[0]!)
        .toSet();
