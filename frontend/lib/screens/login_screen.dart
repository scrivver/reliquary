import 'package:flutter/material.dart';

import '../models/auth_config.dart';
import '../platform_info.dart';
import '../services/auth_service.dart';

const _kAccentRed = Color(0xFFEC3713);

class LoginScreen extends StatefulWidget {
  final AuthService authService;
  final AuthConfig authConfig;
  final VoidCallback onAuthenticated;

  const LoginScreen({
    super.key,
    required this.authService,
    required this.authConfig,
    required this.onAuthenticated,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loadingPassword = false;
  bool _loadingOidc = false;
  String? _error;

  Future<void> _loginPassword() async {
    setState(() {
      _loadingPassword = true;
      _error = null;
    });

    final success = await widget.authService.login(
      _usernameController.text,
      _passwordController.text,
    );

    if (!mounted) return;

    if (success) {
      widget.onAuthenticated();
    } else {
      setState(() {
        _loadingPassword = false;
        _error = 'ACCESS_DENIED: Invalid credentials';
      });
    }
  }

  Future<void> _loginOidc() async {
    setState(() {
      _loadingOidc = true;
      _error = null;
    });

    final success = await widget.authService.loginWithOidc(
      widget.authConfig.oidc,
    );

    if (!mounted) return;

    if (success) {
      widget.onAuthenticated();
    } else {
      setState(() {
        _loadingOidc = false;
        if (!isWebBuild) {
          _error = 'OIDC login failed';
        }
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final passwordEnabled = widget.authConfig.password.enabled;
    final oidcEnabled = widget.authConfig.oidc.enabled;
    final proxyOnly =
        widget.authConfig.proxy.enabled &&
        !passwordEnabled &&
        !oidcEnabled &&
        !widget.authConfig.none.enabled;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: _kAccentRed,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Text(
                        'R',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'RELIQUARY',
                  style: TextStyle(
                    fontFamily: 'Space Grotesk',
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'VAULT_ACCESS_PROTOCOL',
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 10,
                    color: Colors.grey,
                    letterSpacing: 2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                if (passwordEnabled) ...[
                  TextField(
                    controller: _usernameController,
                    decoration: const InputDecoration(labelText: 'IDENTIFIER'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    decoration: const InputDecoration(labelText: 'ACCESS_KEY'),
                    obscureText: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _loginPassword(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: _loadingPassword ? null : _loginPassword,
                      child: _loadingPassword
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('AUTHENTICATE'),
                    ),
                  ),
                ],
                if (passwordEnabled && oidcEnabled) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: Divider(color: Colors.grey[300])),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'OR',
                          style: TextStyle(
                            fontFamily: 'Space Mono',
                            fontSize: 11,
                            color: Colors.grey[500],
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.grey[300])),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                if (oidcEnabled)
                  SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _loadingOidc ? null : _loginOidc,
                      icon: _loadingOidc
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: const Text('SIGN_IN_WITH_OIDC'),
                    ),
                  ),
                if (proxyOnly)
                  Text(
                    isWebBuild
                        ? 'PROXY_AUTH_REQUIRED'
                        : 'PROXY_AUTH_UNSUPPORTED_ON_THIS_CLIENT',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Space Mono',
                      fontSize: 12,
                      color: _kAccentRed,
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _kAccentRed.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontFamily: 'Space Mono',
                        fontSize: 11,
                        color: _kAccentRed,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
