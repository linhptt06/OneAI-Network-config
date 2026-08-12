/// Input checks and the value sets the model is constrained to.
///
/// **Thuộc về app**, dù agent sẽ validate lại. Trùng lặp là có chủ đích:
///
/// * ở app, kiểm tra sớm cho người dùng thông báo rõ ràng mà không tốn một
///   vòng đi tới thiết bị, và các danh sách giá trị bên dưới trở thành ràng
///   buộc grammar nên model không sinh được giá trị ngoài danh sách;
/// * ở agent, kiểm tra lại vì không bao giờ được tin client — kể cả một app
///   hợp lệ cũng có thể có lỗi.
library;

/// Valid `encryption` values for a wifi-iface.
///
/// The `+ccmp` / `+tkip` suffixes pin the cipher and are what MediaTek SDK
/// images actually store (`psk2+ccmp`). They are listed explicitly so the
/// grammar lets the model preserve an existing value instead of being forced
/// to downgrade it to bare `psk2`.
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

/// Valid `proto` values this app supports for the WAN interface.
const List<String> kWanProtocols = ['dhcp', 'static', 'pppoe', 'none'];

/// Longest OS interface name the agent accepts.
///
/// `VALIDATOR_INTERFACE_SIZE` is 16 and the agent requires `length < 16`. The
/// MCP schema advertises `maxLength: 63` for the same field, so a 20-character
/// name passes the protocol layer and then fails inside the tool. Checking the
/// tighter bound here turns that into a clear message instead of a round trip.
const int kMaxInterfaceNameLength = 15;

/// Longest UCI section name the agent accepts (`VALIDATOR_UCI_SECTION_SIZE`).
const int kMaxUciSectionNameLength = 63;

/// Mirrors `validator_uci_section` on the device.
///
/// Letters, digits, `_` and `-` only — no dots, and no leading `@`, which is
/// how UCI writes anonymous sections. The agent rejects those on purpose: an
/// anonymous selector is position-dependent and would silently point at a
/// different section after any edit.
bool isValidUciSectionName(String value) {
  if (value.isEmpty || value.length > kMaxUciSectionNameLength) return false;
  if (value.startsWith('-') || value.startsWith('@')) return false;
  if (value.contains('..')) return false;
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}

/// Mirrors `validator_interface` on the device.
///
/// Wider alphabet than a section name — `.` and `:` appear in VLAN and alias
/// device names — but a much shorter limit.
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

/// Thrown for input that must never reach the device.
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
    // Reject "01" style octets, which some tools accept as octal.
    if (part.length > 1 && part.startsWith('0')) return false;
  }
  return true;
}

/// A netmask must be contiguous ones followed by contiguous zeros.
bool isValidIpv4Netmask(String value) {
  if (!isValidIpv4(value)) return false;
  final octets = value.split('.').map(int.parse).toList();
  var bits = 0;
  for (final octet in octets) {
    bits = (bits << 8) | octet;
  }
  if (bits == 0) return true;
  // ~bits + 1 is a power of two exactly when bits is a valid mask.
  final inverted = (~bits) & 0xFFFFFFFF;
  return (inverted & (inverted + 1)) == 0;
}

/// WPA passphrases are 8..63 characters; anything else is rejected by hostapd
/// and would leave the radio down.
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
