import 'package:flutter/material.dart';

import '../config.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

class SettingsScreen extends StatefulWidget {
  final ApiService? apiService;
  final AuthService? authService;

  const SettingsScreen({super.key, this.apiService, this.authService});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlController;
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  String? _username;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: AppConfig.apiBaseUrl);
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final username = await widget.authService?.getUsername();
    if (mounted) setState(() => _username = username);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    await AppConfig.setApiBaseUrl(url);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Server URL saved. Restart the app to apply.')),
    );
  }

  Future<void> _reset() async {
    await AppConfig.resetApiBaseUrl();
    if (!mounted) return;
    _urlController.text = AppConfig.defaultApiBaseUrl;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Reset to default. Restart the app to apply.')),
    );
  }

  Future<void> _changePassword() async {
    if (_username == null || widget.apiService == null) return;
    final newPassword = _newPasswordController.text.trim();
    if (newPassword.isEmpty) return;

    try {
      await widget.apiService!.changePassword(_username!, newPassword);
      if (!mounted) return;
      _newPasswordController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed successfully')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to change password: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server URL section
          Text('Server URL',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'http://192.168.1.100:2080',
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _reset,
                child: const Text('Reset to Default'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Change the server URL to connect to a different Reliquary instance '
            '(e.g., a portable drive on your local network).',
            style: Theme.of(context).textTheme.bodySmall,
          ),

          // Change password section
          if (_username != null && widget.apiService != null) ...[
            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),
            Text('Change Password',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _newPasswordController,
              decoration: const InputDecoration(
                labelText: 'New Password',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              onSubmitted: (_) => _changePassword(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _changePassword,
              child: const Text('Change Password'),
            ),
          ],
        ],
      ),
    );
  }
}
