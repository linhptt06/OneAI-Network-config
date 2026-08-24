import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

/// Một thiết bị OpenWrt mà app có thể SSH vào.
///
/// Cố ý không có mật khẩu: nó nằm trong keystore hệ thống qua [DeviceStore],
/// không vào SQLite và không vào tham số tool. Model chỉ thấy [alias].
class DeviceProfile {
  final int id;
  final String alias;
  final String host;
  final int port;
  final String username;

  const DeviceProfile({
    required this.id,
    required this.alias,
    required this.host,
    required this.port,
    required this.username,
  });

  factory DeviceProfile.fromRow(Map<String, Object?> row) => DeviceProfile(
    id: row['id'] as int,
    alias: row['alias'] as String,
    host: row['host'] as String,
    port: row['port'] as int,
    username: row['username'] as String,
  );

  /// Phần thông tin model được phép thấy về thiết bị này.
  Map<String, Object?> toModelJson() => {'alias': alias};
}

/// Ánh xạ tên trong câu chat về đúng một bí danh thiết bị đã lưu.
///
/// Model thỉnh thoảng viết chữ chung chung `router` thay vì bí danh thật. Chấp
/// nhận tên rút gọn khi nó chỉ khớp đúng một thiết bị, và fallback về thiết bị
/// duy nhất nếu chỉ có một. Mọi trường hợp nhập nhằng vẫn trả null để không
/// bao giờ kết nối nhầm router.
String? resolveDeviceAlias(String requestedAlias, Iterable<String> aliases) {
  final requested = _normaliseAlias(requestedAlias);
  if (requested.isEmpty) return null;

  final candidates = aliases.toList(growable: false);
  final exact = candidates
      .where((alias) => _normaliseAlias(alias) == requested)
      .toList(growable: false);
  if (exact.length == 1) return exact.single;

  final requestedWords = requested.split(' ');
  final partial = candidates
      .where((alias) {
        final aliasWords = _normaliseAlias(alias).split(' ');
        return requestedWords.every(aliasWords.contains);
      })
      .toList(growable: false);
  if (partial.length == 1) return partial.single;

  // Chỉ có một thiết bị nên không thể chọn nhầm. Nhờ vậy tham số chung chung
  // như "router" vẫn khớp bí danh "oneai", và quay lại khớp nghiêm ngặt ngay
  // khi có thiết bị thứ hai.
  return candidates.length == 1 ? candidates.single : null;
}

String _normaliseAlias(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Lưu hồ sơ thiết bị, tách phần bí mật khỏi phần không bí mật.
class DeviceStore {
  DeviceStore(this._db, {FlutterSecureStorage? secureStorage})
    : _secure = secureStorage ?? const FlutterSecureStorage();

  final Database _db;
  final FlutterSecureStorage _secure;

  static const _passwordKeyPrefix = 'openwrt_password_';

  Future<void> ensureTable() async {
    await _db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        alias    TEXT    NOT NULL UNIQUE,
        host     TEXT    NOT NULL,
        port     INTEGER NOT NULL DEFAULT 22,
        username TEXT    NOT NULL
      )
    ''');
  }

  Future<List<DeviceProfile>> list() async {
    await ensureTable();
    final rows = await _db.query('devices', orderBy: 'alias ASC');
    return rows.map(DeviceProfile.fromRow).toList();
  }

  Future<DeviceProfile?> findByAlias(String alias) async {
    await ensureTable();
    final rows = await _db.query(
      'devices',
      where: 'alias = ?',
      whereArgs: [alias],
      limit: 1,
    );
    return rows.isEmpty ? null : DeviceProfile.fromRow(rows.first);
  }

  Future<DeviceProfile> upsert({
    int? id,
    required String alias,
    required String host,
    int port = 22,
    required String username,
    String? password,
  }) async {
    await ensureTable();
    final values = {
      'alias': alias,
      'host': host,
      'port': port,
      'username': username,
    };

    final int deviceId;
    if (id == null) {
      deviceId = await _db.insert(
        'devices',
        values,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      await _db.update('devices', values, where: 'id = ?', whereArgs: [id]);
      deviceId = id;
    }

    // Mật khẩu null khi sửa nghĩa là "giữ nguyên cái đã lưu", không phải "xoá".
    if (password != null) {
      await _secure.write(key: '$_passwordKeyPrefix$deviceId', value: password);
    }

    return DeviceProfile(
      id: deviceId,
      alias: alias,
      host: host,
      port: port,
      username: username,
    );
  }

  Future<void> delete(int id) async {
    await ensureTable();
    await _db.delete('devices', where: 'id = ?', whereArgs: [id]);
    await _secure.delete(key: '$_passwordKeyPrefix$id');
  }

  /// Đọc mật khẩu thiết bị. Chỉ tầng SSH gọi hàm này.
  Future<String?> passwordFor(int deviceId) =>
      _secure.read(key: '$_passwordKeyPrefix$deviceId');
}
