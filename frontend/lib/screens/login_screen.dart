import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config.dart';
import '../services/auth_service.dart';
import 'app_shell.dart';

class LoginScreen extends StatefulWidget {
  final AuthService authService;

  const LoginScreen({super.key, required this.authService});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final success = await widget.authService.login(
      _usernameController.text,
      _passwordController.text,
    );

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => AppShell(authService: widget.authService),
        ),
      );
    } else {
      setState(() {
        _loading = false;
        _error = 'ACCESS_DENIED: Invalid credentials';
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showServerConfig() {
    final controller = TextEditingController(text: AppConfig.apiBaseUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('SERVER_ENDPOINT', style: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w700, letterSpacing: 1.0,
        )),
        content: TextField(
          controller: controller,
          style: GoogleFonts.spaceMono(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'http://192.168.1.100:2080',
            hintStyle: GoogleFonts.spaceMono(fontSize: 13, color: Colors.grey[400]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await AppConfig.resetApiBaseUrl();
              controller.text = AppConfig.defaultApiBaseUrl;
            },
            child: const Text('RESET'),
          ),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isNotEmpty) {
                await AppConfig.setApiBaseUrl(url);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    ).then((_) => controller.dispose());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, size: 20),
            onPressed: _showServerConfig,
            tooltip: 'SERVER_CONFIG',
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo
                Center(
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC3713),
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
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  'VAULT_ACCESS_PROTOCOL',
                  style: GoogleFonts.spaceMono(
                    fontSize: 10,
                    color: Colors.grey,
                    letterSpacing: 2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'IDENTIFIER',
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'ACCESS_KEY',
                  ),
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _login(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC3713).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(_error!,
                        style: GoogleFonts.spaceMono(
                            fontSize: 11, color: const Color(0xFFEC3713))),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _login,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('AUTHENTICATE'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
