/// Các phép kiểm đầu vào phía app.
///
/// **Thuộc về app**, dù agent sẽ validate lại. Trùng lặp là có chủ đích:
///
/// * ở app, kiểm sớm để báo lỗi rõ cho người dùng mà không tốn một vòng đi
///   tới thiết bị;
/// * ở agent, kiểm lại vì không bao giờ được tin client — kể cả app hợp lệ
///   cũng có thể có lỗi.
///
/// Ràng buộc grammar cho model nằm ở `net_tools.dart` (`ToolParam.enumType`),
/// không phải ở đây.
library;

/// Các giá trị `encryption` hợp lệ của một wifi-iface.
///
/// Hậu tố `+ccmp` / `+tkip` ghim cipher và đúng là thứ firmware MediaTek lưu
/// (`psk2+ccmp`). Liệt kê tường minh để giữ được giá trị sẵn có thay vì hạ
/// xuống `psk2` trơn.
///
/// Chưa có tool ghi WiFi nào dùng danh sách này; hiện chỉ test tham chiếu tới.
const List<String> kWifiEncryptionModes = [
  'none',
  'psk',
  'psk2',
  'psk2+ccmp',
  'psk-mixed',
  'psk-mixed+ccmp',
  'sae',
  'sae-mixed',
  'sae-mixed+ccmp',
  'owe',
];

/// Các giá trị `proto` app hỗ trợ cho interface WAN. Cũng chưa có tool nào
/// dùng tới.
const List<String> kWanProtocols = ['dhcp', 'static', 'pppoe', 'none'];

/// Độ dài tối đa của tên cổng mạng mà agent chấp nhận.
///
/// Agent yêu cầu `length < 16`, nhưng schema MCP lại khai `maxLength: 63` cho
/// cùng field — nên tên 20 ký tự lọt qua tầng giao thức rồi mới hỏng bên trong
/// tool. Kiểm cận chặt hơn ở đây để báo lỗi rõ thay vì tốn một vòng đi router.
const int kMaxInterfaceNameLength = 15;

/// Độ dài tối đa của tên section UCI mà agent chấp nhận.
const int kMaxUciSectionNameLength = 63;

/// Bản sao của `validator_uci_section` trên thiết bị.
///
/// Chỉ chữ, số, `_` và `-`: không có dấu chấm, không mở đầu bằng `@` (cách UCI
/// viết section vô danh). Agent cố ý từ chối `@` vì bộ chọn vô danh phụ thuộc
/// vị trí, sau một lần sửa là âm thầm trỏ sang section khác.
bool isValidUciSectionName(String value) {
  if (value.isEmpty || value.length > kMaxUciSectionNameLength) return false;
  if (value.startsWith('-') || value.startsWith('@')) return false;
  if (value.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}

/// Bản sao của `validator_interface` trên thiết bị.
///
/// Bộ ký tự rộng hơn tên section — `.` và `:` xuất hiện trong tên VLAN và
/// alias — nhưng giới hạn độ dài ngắn hơn nhiều.
bool isValidInterfaceName(String value) {
  if (value.isEmpty || value.length > kMaxInterfaceNameLength) return false;
  if (value.startsWith('-') || value.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value);
}

void validateUciSectionName(String value, String label) {
  if (!isValidUciSectionName(value)) {
    throw UciValidationException(
      '$label không hợp lệ: "$value". Chỉ dùng chữ, số, "_" và "-".',
    );
  }
}

void validateInterfaceName(String value) {
  if (!isValidInterfaceName(value)) {
    throw UciValidationException(
      'Tên cổng mạng không hợp lệ: "$value". '
      'Tối đa $kMaxInterfaceNameLength ký tự, ví dụ br-lan hoặc eth0.',
    );
  }
}

/// Ném ra với đầu vào không bao giờ được phép tới thiết bị.
class UciValidationException implements Exception {
  UciValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool isValidIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return false;
    // Chặn octet kiểu "01" vì một số công cụ hiểu thành số bát phân.
    if (part.length > 1 && part.startsWith('0')) return false;
  }
  return true;
}

/// Netmask phải là một dãy bit 1 liền nhau rồi tới một dãy bit 0 liền nhau.
bool isValidIpv4Netmask(String value) {
  if (!isValidIpv4(value)) return false;
  final octets = value.split('.').map(int.parse).toList();
  var bits = 0;
  for (final octet in octets) {
    bits = (bits << 8) | octet;
  }
  if (bits == 0) return true;
  // ~bits + 1 là luỹ thừa của 2 đúng khi bits là một mask hợp lệ.
  final inverted = (~bits) & 0xFFFFFFFF;
  return (inverted & (inverted + 1)) == 0;
}

/// Mật khẩu WPA dài 8..63 ký tự; ngoài khoảng đó hostapd từ chối và radio sẽ
/// không lên. Chưa có tool ghi nào gọi tới.
void validateWifiPassword(String password, String encryption) {
  if (encryption == 'none' || encryption == 'owe') return;
  if (password.length < 8 || password.length > 63) {
    throw UciValidationException(
      'Mật khẩu WiFi phải dài 8–63 ký tự (đang là ${password.length}).',
    );
  }
}

void validateSsid(String ssid) {
  if (ssid.isEmpty || ssid.length > 32) {
    throw UciValidationException('SSID phải dài 1–32 ký tự.');
  }
}

void validateVlanId(int vlanId) {
  if (vlanId < 1 || vlanId > 4094) {
    throw UciValidationException('VLAN ID phải nằm trong khoảng 1–4094.');
  }
}

void validateIpv4(String value, String label) {
  if (!isValidIpv4(value)) {
    throw UciValidationException(
      '$label không phải địa chỉ IPv4 hợp lệ: $value',
    );
  }
}

void validateNetmask(String value) {
  if (!isValidIpv4Netmask(value)) {
    throw UciValidationException('Subnet mask không hợp lệ: $value');
  }
}
