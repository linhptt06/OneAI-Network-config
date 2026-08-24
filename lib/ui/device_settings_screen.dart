import 'package:flutter/material.dart';

import '../net/device_profile.dart';
import 'app_theme.dart';

/// Quản lý danh sách thiết bị OpenWrt đã lưu.
///
/// Đây là nơi duy nhất mật khẩu được nhập và lưu. Tool chỉ nhận bí danh, không
/// bao giờ nhận thông tin đăng nhập.
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

  /// Xoá thiết bị cũng xoá mật khẩu trong keystore, nên hỏi lại một lần.
  Future<void> _confirmDelete(DeviceProfile device) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá thiết bị?'),
        content: Text(
          '“${device.alias}” và mật khẩu SSH đã lưu sẽ bị xoá khỏi máy.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await widget.store.delete(device.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Thiết bị OpenWrt')),
      body: _devices.isEmpty
          ? const EmptyState(
              icon: Icons.router_outlined,
              title: 'Chưa có thiết bị nào',
              message:
                  'Thêm router OpenWrt để chatbot có thể đọc và cấu hình '
                  'qua SSH trong mạng LAN.',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: _devices.length,
              itemBuilder: (context, index) {
                final device = _devices[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(AppTheme.radius),
                    child: InkWell(
                      onTap: () => _edit(existing: device),
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer.withValues(
                                  alpha: 0.6,
                                ),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(
                                Icons.router_outlined,
                                size: 19,
                                color: scheme.onPrimaryContainer,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    device.alias,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${device.username}@${device.host}'
                                    ':${device.port}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          fontFamily: 'monospace',
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              tooltip: 'Xoá',
                              color: scheme.outline,
                              onPressed: () => _confirmDelete(device),
                            ),
                          ],
                        ),
                      ),
                    ),
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
  bool _showPassword = false;

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
      // Để trống khi sửa nghĩa là "giữ nguyên mật khẩu cũ".
      password: _password.text.isEmpty ? null : _password.text,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    final scheme = Theme.of(context).colorScheme;

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
                textCapitalization: TextCapitalization.none,
                decoration: const InputDecoration(
                  labelText: 'Bí danh',
                  helperText: 'Tên chatbot dùng để gọi, ví dụ: RouterNha',
                  helperMaxLines: 2,
                  prefixIcon: Icon(Icons.badge_outlined, size: 20),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Bắt buộc' : null,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _host,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Địa chỉ IP',
                  helperText: 'Ví dụ 192.168.1.1 — emulator: 10.0.2.2',
                  prefixIcon: Icon(Icons.lan_outlined, size: 20),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Bắt buộc' : null,
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: 'Tên đăng nhập',
                        prefixIcon: Icon(Icons.person_outline, size: 20),
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Bắt buộc' : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _port,
                      decoration: const InputDecoration(labelText: 'Cổng'),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final port = int.tryParse(v?.trim() ?? '');
                        return (port == null || port < 1 || port > 65535)
                            ? 'Sai'
                            : null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: 'Mật khẩu',
                  helperText: isNew
                      ? 'Lưu vào keystore, không vào SQLite'
                      : 'Để trống nếu không đổi mật khẩu',
                  prefixIcon: const Icon(Icons.lock_outline, size: 20),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    tooltip: _showPassword ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
                validator: (v) =>
                    (isNew && (v == null || v.isEmpty)) ? 'Bắt buộc' : null,
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Dùng IP phía LAN. Mật khẩu không đi qua model.',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
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
