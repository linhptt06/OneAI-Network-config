import 'package:flutter/material.dart';

import '../net/device_profile.dart';

/// Manages the saved OpenWrt devices.
///
/// This is the only place a password is ever entered or stored. Tools receive
/// an alias, never credentials.
class DeviceSettingsScreen extends StatefulWidget {
  const DeviceSettingsScreen({super.key, required this.store});

  final DeviceStore store;

  @override
  State<DeviceSettingsScreen> createState() => _DeviceSettingsScreenState();
}

class _DeviceSettingsScreenState extends State<DeviceSettingsScreen> {
  List<DeviceProfile> _devices = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final devices = await widget.store.list();
    if (mounted) setState(() => _devices = devices);
  }

  Future<void> _edit({DeviceProfile? existing}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _DeviceEditDialog(store: widget.store, existing: existing),
    );
    if (saved == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Thiết bị OpenWrt')),
      body: _devices.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Chưa có thiết bị nào.\n\n'
                  'Thêm router OpenWrt để chatbot có thể đọc và cấu hình '
                  'qua SSH.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              itemCount: _devices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final device = _devices[index];
                return ListTile(
                  leading: const Icon(Icons.router_outlined),
                  title: Text(device.alias),
                  subtitle: Text(
                    '${device.username}@${device.host}:${device.port}',
                  ),
                  onTap: () => _edit(existing: device),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await widget.store.delete(device.id);
                      await _refresh();
                    },
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Thêm thiết bị'),
      ),
    );
  }
}

class _DeviceEditDialog extends StatefulWidget {
  const _DeviceEditDialog({required this.store, this.existing});

  final DeviceStore store;
  final DeviceProfile? existing;

  @override
  State<_DeviceEditDialog> createState() => _DeviceEditDialogState();
}

class _DeviceEditDialogState extends State<_DeviceEditDialog> {
  late final _alias = TextEditingController(text: widget.existing?.alias);
  late final _host = TextEditingController(text: widget.existing?.host);
  late final _port = TextEditingController(
    text: '${widget.existing?.port ?? 22}',
  );
  late final _username = TextEditingController(
    text: widget.existing?.username ?? 'root',
  );
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in [_alias, _host, _port, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    await widget.store.upsert(
      id: widget.existing?.id,
      alias: _alias.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      username: _username.text.trim(),
      // Empty on edit means "keep the existing password".
      password: _password.text.isEmpty ? null : _password.text,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return AlertDialog(
      title: Text(isNew ? 'Thêm thiết bị' : 'Sửa thiết bị'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _alias,
                decoration: const InputDecoration(
                  labelText: 'Bí danh',
                  helperText: 'Tên chatbot dùng để gọi, ví dụ: RouterNha',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Bắt buộc' : null,
              ),
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Địa chỉ IP',
                  helperText: 'Ví dụ 192.168.1.1. Từ emulator, máy tính '
                      'host là 10.0.2.2',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Bắt buộc' : null,
              ),
              TextFormField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Cổng SSH'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final port = int.tryParse(v?.trim() ?? '');
                  return (port == null || port < 1 || port > 65535)
                      ? 'Cổng không hợp lệ'
                      : null;
                },
              ),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: 'Tên đăng nhập'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Bắt buộc' : null,
              ),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  helperText: isNew
                      ? 'Lưu vào keystore của hệ thống, không vào SQLite'
                      : 'Để trống nếu không đổi mật khẩu',
                ),
                validator: (v) => (isNew && (v == null || v.isEmpty))
                    ? 'Bắt buộc'
                    : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Hủy'),
        ),
        FilledButton(onPressed: _save, child: const Text('Lưu')),
      ],
    );
  }
}
