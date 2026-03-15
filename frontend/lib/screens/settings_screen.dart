import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

const _kAccentRed = Color(0xFFEC3713);

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
      SnackBar(
          content: Text('Server URL saved. Restart the app to apply.',
              style: GoogleFonts.spaceMono(fontSize: 13))),
    );
  }

  Future<void> _reset() async {
    await AppConfig.resetApiBaseUrl();
    if (!mounted) return;
    _urlController.text = AppConfig.defaultApiBaseUrl;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Reset to default. Restart the app to apply.',
              style: GoogleFonts.spaceMono(fontSize: 13))),
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
        SnackBar(content: Text('Password changed successfully',
            style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to change password: $e',
            style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'SYSTEM_CONFIG',
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server URL section
          _buildSectionHeader('SERVER_URL'),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            style: GoogleFonts.spaceMono(fontSize: 14),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: _kAccentRed),
              ),
              hintText: 'http://192.168.1.100:2080',
              hintStyle: GoogleFonts.spaceMono(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
              ),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
                  onPressed: _save,
                  child: Text('SAVE', style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                  )),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _kAccentRed),
                  foregroundColor: _kAccentRed,
                ),
                onPressed: _reset,
                child: Text('RESET_DEFAULT', style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                )),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Change the server URL to connect to a different Reliquary instance '
            '(e.g., a portable drive on your local network).',
            style: GoogleFonts.spaceMono(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),

          // Change password section
          if (_username != null && widget.apiService != null) ...[
            const SizedBox(height: 32),
            Divider(color: Theme.of(context).colorScheme.outlineVariant),
            const SizedBox(height: 16),
            _buildSectionHeader('CHANGE_PASSWORD'),
            const SizedBox(height: 12),
            TextField(
              controller: _newPasswordController,
              style: GoogleFonts.spaceMono(fontSize: 14),
              decoration: InputDecoration(
                labelText: 'NEW_PASSWORD',
                labelStyle: GoogleFonts.spaceMono(fontSize: 12, letterSpacing: 1.0),
                border: const OutlineInputBorder(),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: _kAccentRed),
                ),
              ),
              obscureText: true,
              onSubmitted: (_) => _changePassword(),
            ),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
              onPressed: _changePassword,
              child: Text('CHANGE_PASSWORD', style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              )),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Row(
      children: [
        Container(width: 3, height: 16, color: _kAccentRed),
        const SizedBox(width: 8),
        Text(
          title,
          style: GoogleFonts.spaceGrotesk(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
