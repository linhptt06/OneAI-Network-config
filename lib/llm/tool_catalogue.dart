import 'package:llamadart/llamadart.dart';

/// Narrows app-owned tool schemas to capabilities advertised by a router.
///
/// The router contributes names only; descriptions and parameter schemas stay
/// in the app, so device output can never become model prompt text.
List<ToolDefinition> negotiateTools(
  List<ToolDefinition> appTools,
  Set<String> deviceToolNames,
) => appTools.where((tool) => deviceToolNames.contains(tool.name)).toList();
