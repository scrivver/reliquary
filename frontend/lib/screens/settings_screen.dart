import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../platform_info.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'responsive_page.dart';

const _kPrimary = Color(0xFFB7102A);
const _kSurface = Color(0xFFF8F9FA);
const _kCard = Color(0xFFFFFFFF);
const _kBorder = Color(0xFFE5E5E5);
const _kText = Color(0xFF191C1D);
const _kSecondary = Color(0xFF5F5E5E);
const _kMutedSurface = Color(0xFFEDEEEF);

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
  final _confirmPasswordController = TextEditingController();
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
    _confirmPasswordController.dispose();
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
          style: TextStyle(fontFamily: 'Inter', fontSize: 13),
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
          style: TextStyle(fontFamily: 'Inter', fontSize: 13),
        ),
      ),
    );
  }

  Future<void> _changePassword() async {
    if (_username == null || widget.apiService == null) return;
    final currentPassword = _currentPasswordController.text.trim();
    final newPassword = _newPasswordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();
    if (currentPassword.isEmpty ||
        newPassword.isEmpty ||
        confirmPassword.isEmpty) {
      _showSnackBar('Enter current password, new password, and confirmation.');
      return;
    }
    if (newPassword != confirmPassword) {
      _showSnackBar('New password and confirmation do not match.');
      return;
    }

    try {
      await widget.apiService!.changeOwnPassword(currentPassword, newPassword);
      if (!mounted) return;
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      _showSnackBar('Password changed. Other devices have been signed out.');
    } on DioException catch (e) {
      if (!mounted) return;
      if (e.response?.statusCode == 403) {
        _showSnackBar('Current password is incorrect.');
      } else {
        _showSnackBar('Failed to change password: ${e.message}');
      }
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('Failed to change password: $e');
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(fontFamily: 'Inter', fontSize: 13),
        ),
      ),
    );
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
      backgroundColor: _kSurface,
      body: isDesktop ? _buildDesktopBody() : _buildMobileBody(),
    );
  }

  /// A password can only be changed where Reliquary is the one holding it.
  bool get _canChangePassword =>
      _username != null && _provider == 'password' && widget.apiService != null;

  /// An OIDC session has no Reliquary-side password: the credential lives in
  /// the identity provider, and `/api/users/me/password` is not even served.
  bool get _isOidcSession => _provider == 'oidc';

  Widget _buildMobileBody() {
    final hasSettings = !isWebBuild || _canChangePassword || _isOidcSession;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        if (!isWebBuild)
          _ConfigPanel(
            icon: Icons.dns_outlined,
            title: 'Server Endpoint',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _serverUrlFields(),
            ),
          ),

        // Change password section
        if (_canChangePassword) ...[
          if (!isWebBuild) const SizedBox(height: 16),
          _ConfigPanel(
            icon: Icons.lock_reset,
            title: 'Security Credentials',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _changePasswordFields(),
            ),
          ),
        ] else if (_isOidcSession) ...[
          if (!isWebBuild) const SizedBox(height: 16),
          _ConfigPanel(
            icon: Icons.shield_outlined,
            title: 'Security Credentials',
            child: _ExternalCredentialsLabel(username: _username),
          ),
        ],
        if (!hasSettings) ...[
          if (!isWebBuild) const SizedBox(height: 16),
          const _ConfigPanel(
            icon: Icons.info_outline,
            title: 'Current Session',
            child: _NoSettingsLabel(),
          ),
        ],
      ],
    );
  }

  Widget _buildDesktopBody() {
    final sections = <Widget>[];

    if (_canChangePassword) {
      sections.add(
        _ConfigPanel(
          icon: Icons.lock_reset,
          title: 'Security Credentials',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _changePasswordFields(),
          ),
        ),
      );
    } else if (_isOidcSession) {
      sections.add(
        _ConfigPanel(
          icon: Icons.shield_outlined,
          title: 'Security Credentials',
          child: _ExternalCredentialsLabel(username: _username),
        ),
      );
    }

    if (!isWebBuild) {
      if (sections.isNotEmpty) sections.add(const SizedBox(height: 24));
      sections.add(
        _ConfigPanel(
          icon: Icons.dns_outlined,
          title: 'Server Endpoint',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _serverUrlFields(),
          ),
        ),
      );
    }

    if (sections.isEmpty) {
      sections.add(
        const _ConfigPanel(
          icon: Icons.info_outline,
          title: 'Current Session',
          child: _NoSettingsLabel(),
        ),
      );
    }

    return SingleChildScrollView(
      child: DesktopPageFrame(
        maxWidth: 1440,
        padding: const EdgeInsets.fromLTRB(40, 40, 40, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const DesktopPageHeader(
              title: 'System Config',
              subtitle:
                  'Manage connection and account security settings for this Reliquary session.',
            ),
            const SizedBox(height: 48),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: sections,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _serverUrlFields() {
    return [
      const _ConfigFieldLabel('Server URL'),
      const SizedBox(height: 8),
      TextField(
        controller: _urlController,
        style: const TextStyle(fontFamily: 'Geist', fontSize: 14),
        decoration: _inputDecoration(hintText: 'http://192.168.1.100:2080'),
        keyboardType: TextInputType.url,
        onSubmitted: (_) => _save(),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _kPrimary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _save,
            child: const Text(
              'SAVE',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _kText),
              foregroundColor: _kText,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _reset,
            child: const Text(
              'RESET',
              style: TextStyle(
                fontFamily: 'Inter',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        'Change the server URL to connect to a different Reliquary instance.',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          height: 20 / 14,
          color: _kSecondary,
        ),
      ),
    ];
  }

  List<Widget> _changePasswordFields() {
    return [
      const _ConfigFieldLabel('Current Password'),
      const SizedBox(height: 8),
      TextField(
        controller: _currentPasswordController,
        style: const TextStyle(fontFamily: 'Geist', fontSize: 14),
        decoration: _inputDecoration(hintText: 'Enter current password'),
        obscureText: true,
      ),
      const SizedBox(height: 24),
      LayoutBuilder(
        builder: (context, constraints) {
          final fields = [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _ConfigFieldLabel('New Password'),
                const SizedBox(height: 8),
                TextField(
                  controller: _newPasswordController,
                  style: const TextStyle(fontFamily: 'Geist', fontSize: 14),
                  decoration: _inputDecoration(hintText: 'Enter new password'),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Use a strong password for this account.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    height: 20 / 14,
                    color: _kSecondary,
                  ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _ConfigFieldLabel('Confirm New Password'),
                const SizedBox(height: 8),
                TextField(
                  controller: _confirmPasswordController,
                  style: const TextStyle(fontFamily: 'Geist', fontSize: 14),
                  decoration: _inputDecoration(hintText: 'Verify new password'),
                  obscureText: true,
                  onSubmitted: (_) => _changePassword(),
                ),
              ],
            ),
          ];

          if (constraints.maxWidth < 720) {
            return Column(
              children: [fields[0], const SizedBox(height: 16), fields[1]],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: fields[0]),
              const SizedBox(width: 24),
              Expanded(child: fields[1]),
            ],
          );
        },
      ),
      const SizedBox(height: 24),
      const Text(
        'The current password is required before a new credential is accepted.',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          height: 20 / 14,
          color: _kSecondary,
        ),
      ),
      const SizedBox(height: 24),
      Container(height: 1, color: _kBorder),
      const SizedBox(height: 24),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _kPrimary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: _changePassword,
        child: const Text(
          'CHANGE PASSWORD',
          style: TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
        ),
      ),
    ];
  }

  InputDecoration _inputDecoration({String? hintText}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(
        fontFamily: 'Geist',
        fontSize: 14,
        color: _kSecondary,
      ),
      filled: true,
      fillColor: _kSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: _kPrimary),
      ),
    );
  }
}

/// Shown in place of the change-password form for sessions whose credential is
/// held elsewhere. Without it the panel simply vanishes under SSO, which reads
/// as a missing feature rather than as a deliberate boundary.
class _ExternalCredentialsLabel extends StatelessWidget {
  final String? username;

  const _ExternalCredentialsLabel({this.username});

  @override
  Widget build(BuildContext context) {
    // The username is best-effort under OIDC: it is resolved from the
    // provider's userinfo endpoint after the token exchange, which can fail.
    final signedIn = username == null
        ? 'Signed in via SSO.'
        : 'Signed in as $username via SSO.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          signedIn,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            height: 20 / 14,
            fontWeight: FontWeight.w600,
            color: _kText,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Password changes are handled by your identity provider, '
          'not Reliquary.',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            height: 20 / 14,
            color: _kSecondary,
          ),
        ),
      ],
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

class _ConfigPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _ConfigPanel({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: _kMutedSurface,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: _kPrimary, size: 22),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 20,
                  height: 28 / 20,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: _kText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          child,
        ],
      ),
    );
  }
}

class _ConfigFieldLabel extends StatelessWidget {
  final String text;

  const _ConfigFieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.96,
        color: _kSecondary,
      ),
    );
  }
}
