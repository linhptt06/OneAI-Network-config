import 'package:llamadart/llamadart.dart';

/// Lọc schema tool của app theo danh sách capability router khai báo.
///
/// Router chỉ góp tên; mô tả và schema tham số vẫn thuộc app, nên dữ liệu từ
/// thiết bị không bao giờ trở thành prompt của model.
List<ToolDefinition> negotiateTools(
  List<ToolDefinition> appTools,
  Set<String> deviceToolNames,
) => appTools.where((tool) => deviceToolNames.contains(tool.name)).toList();
