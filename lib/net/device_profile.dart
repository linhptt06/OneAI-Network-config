import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

/// An OpenWrt device the app can SSH into.
///
/// The password is deliberately absent: it lives in the platform keystore via
/// [DeviceStore], never in SQLite and never in a tool argument. The model only
/// ever sees [alias].
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

  /// What the model is allowed to see about this device.
  Map<String, Object?> toModelJson() => {'alias': alias};
}

/// Resolves a name supplied in a chat request to one saved device alias.
///
/// The model occasionally emits the generic word `router` instead of the
/// saved alias (for example `oneai`). Treating that as an automatic failure
/// makes a one-router setup need a second model turn. We accept a shortened
/// name when it identifies exactly one saved device, and fall back to the
/// only saved device when there is one. Anything ambiguous still returns null
/// so the caller never connects to an arbitrary router.
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

  // There is no alternative device to accidentally select. This makes a
  // generic model argument such as "router" work with a saved alias such as
  // "oneai", while retaining strict matching as soon as a second device is
  // configured.
  return candidates.length == 1 ? candidates.single : null;
}

String _normaliseAlias(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Stores device profiles, splitting secrets from non-secrets.
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

    // A null password on edit means "keep the stored one" rather than "clear".
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

  /// Reads a device password. Only the SSH layer calls this.
  Future<String?> passwordFor(int deviceId) =>
      _secure.read(key: '$_passwordKeyPrefix$deviceId');
}
