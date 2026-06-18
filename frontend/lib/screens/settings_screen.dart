import 'package:flutter/material.dart';

import '../config.dart';
import '../platform_info.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'responsive_page.dart';

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
  String? _provider;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: AppConfig.apiBaseUrl);
    _loadUsername();
  }

  Future<void> _loadUsername() async {
    final username = await widget.authService?.getUsername();
    final provider = await widget.authService?.getProvider();
    if (mounted) {
      setState(() {
        _username = username;
        _provider = provider;
      });
    }
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
        content: Text(
          'Server URL saved. Restart the app to apply.',
          style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
        ),
      ),
    );
  }

  Future<void> _reset() async {
    await AppConfig.resetApiBaseUrl();
    if (!mounted) return;
    _urlController.text = AppConfig.defaultApiBaseUrl;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Reset to default. Restart the app to apply.',
          style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
        ),
      ),
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
        SnackBar(
          content: Text(
            'Password changed successfully',
            style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to change password: $e',
            style: TextStyle(fontFamily: 'Space Mono', fontSize: 13),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = isDesktopWidth(context);
    return Scaffold(
      appBar: isDesktop
          ? null
          : AppBar(
              title: Text(
                'System Config',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
      body: isDesktop ? _buildDesktopBody() : _buildMobileBody(),
    );
  }

  Widget _buildMobileBody() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!isWebBuild) ..._serverUrlFields(),

        // Change password section
        if (_username != null &&
            _provider == 'password' &&
            widget.apiService != null) ...[
          if (!isWebBuild) const SizedBox(height: 32),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          ..._changePasswordFields(),
        ],
      ],
    );
  }

  Widget _buildDesktopBody() {
    final sections = <Widget>[];

    if (!isWebBuild) {
      sections.add(
        PageSectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _serverUrlFields(),
          ),
        ),
      );
    }

    if (_username != null &&
        _provider == 'password' &&
        widget.apiService != null) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 16));
      sections.add(
        PageSectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _changePasswordFields(),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      child: DesktopPageFrame(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'System Config',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 32,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Connection and account settings for the current desktop session.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                height: 1.45,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.64),
              ),
            ),
            const SizedBox(height: 32),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kDesktopFormMaxWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: sections.isEmpty
                        ? [const PageSectionCard(child: _NoSettingsLabel())]
                        : sections,
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(
                  width: 280,
                  child: PageSectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Current session',
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _ConfigInfoRow(label: 'User', value: _username ?? '-'),
                        _ConfigInfoRow(
                          label: 'Provider',
                          value: _provider ?? '-',
                        ),
                        if (!isWebBuild)
                          _ConfigInfoRow(
                            label: 'Server',
                            value: _urlController.text,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _serverUrlFields() {
    return [
      _buildSectionHeader('Server URL'),
      const SizedBox(height: 12),
      TextField(
        controller: _urlController,
        style: TextStyle(fontFamily: 'Geist', fontSize: 14),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: _kAccentRed),
          ),
          hintText: 'http://192.168.1.100:2080',
          hintStyle: TextStyle(
            fontFamily: 'Geist',
            fontSize: 14,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.3),
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
              child: Text(
                'SAVE',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kAccentRed),
              foregroundColor: _kAccentRed,
            ),
            onPressed: _reset,
            child: Text(
              'Reset',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        'Change the server URL to connect to a different Reliquary instance '
        '(e.g., a portable drive on your local network).',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 13,
          height: 1.45,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    ];
  }

  List<Widget> _changePasswordFields() {
    return [
      _buildSectionHeader('Change Password'),
      const SizedBox(height: 12),
      TextField(
        controller: _newPasswordController,
        style: TextStyle(fontFamily: 'Geist', fontSize: 14),
        decoration: InputDecoration(
          labelText: 'New password',
          labelStyle: TextStyle(fontFamily: 'Inter', fontSize: 12),
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
        child: Text(
          'Change password',
          style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
        ),
      ),
    ];
  }

  Widget _buildSectionHeader(String title) {
    return Row(
      children: [
        Container(width: 3, height: 16, color: _kAccentRed),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.96,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class _ConfigInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _ConfigInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Geist',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoSettingsLabel extends StatelessWidget {
  const _NoSettingsLabel();

  @override
  Widget build(BuildContext context) {
    return Text(
      'No configurable settings are available for this session.',
      style: TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
      ),
    );
  }
}
