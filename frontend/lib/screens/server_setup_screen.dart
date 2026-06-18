import 'package:flutter/material.dart';

import '../config.dart';
import '../services/auth_service.dart';

const _kAccentRed = Color(0xFFEC3713);

class ServerSetupScreen extends StatefulWidget {
  final AuthService authService;
  final String? error;
  final VoidCallback onConfigured;

  const ServerSetupScreen({
    super.key,
    required this.authService,
    required this.onConfigured,
    this.error,
  });

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _controller = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.error;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = AppConfig.normalizeBaseUrl(_controller.text);
    if (url.isEmpty) return;

    setState(() {
      _checking = true;
      _error = null;
    });

    try {
      await widget.authService.getAuthConfig(baseUrl: url);
      await AppConfig.setApiBaseUrl(url);
      if (!mounted) return;
      widget.onConfigured();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = 'Unable to reach Reliquary server';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'SERVER_ENDPOINT',
                  style: TextStyle(
                    fontFamily: 'Space Grotesk',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: 'RELIQUARY_URL',
                    hintText: 'https://reliquary.example.com',
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _connect(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontFamily: 'Space Mono',
                      fontSize: 12,
                      color: _kAccentRed,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _checking ? null : _connect,
                    child: _checking
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('CONNECT'),
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
