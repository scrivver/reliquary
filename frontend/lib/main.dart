import 'package:flutter/material.dart';

import 'config.dart';
import 'models/auth_config.dart';
import 'platform_info.dart';
import 'screens/app_shell.dart';
import 'screens/login_screen.dart';
import 'screens/server_setup_screen.dart';
import 'services/auth_service.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();
const appTitle = 'Reliquary';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppConfig.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      navigatorKey: navigatorKey,
      theme: ReliquaryTheme.light,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _authService = AuthService();
  bool _checking = true;
  bool _loggedIn = false;
  bool _needsServerSetup = false;
  String? _error;
  AuthConfig? _authConfig;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    if (requiresConfiguredServerUrl && !AppConfig.hasSavedApiBaseUrl) {
      setState(() {
        _needsServerSetup = true;
        _checking = false;
      });
      return;
    }

    try {
      final config = await _authService.getAuthConfig();
      final completedRedirect = await _authService
          .completeOidcRedirectIfPresent(config.oidc);
      final loggedIn = completedRedirect || await _authService.isLoggedIn();
      final shouldEnter =
          config.none.enabled ||
          (isWebBuild && config.proxy.enabled && !config.hasInteractiveLogin) ||
          loggedIn;

      if (mounted) {
        setState(() {
          _authConfig = config;
          _loggedIn = shouldEnter;
          _checking = false;
          _needsServerSetup = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Unable to load auth config: $e';
          _needsServerSetup = requiresConfiguredServerUrl;
          _checking = false;
        });
      }
    }
  }

  void _onServerConfigured() {
    setState(() {
      _checking = true;
      _needsServerSetup = false;
      _error = null;
    });
    _checkAuth();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_needsServerSetup) {
      return ServerSetupScreen(
        authService: _authService,
        error: _error,
        onConfigured: _onServerConfigured,
      );
    }

    if (_error != null && _authConfig == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(onPressed: _checkAuth, child: const Text('RETRY')),
              ],
            ),
          ),
        ),
      );
    }

    if (_loggedIn) {
      return AppShell(authService: _authService);
    }

    return LoginScreen(
      authService: _authService,
      authConfig: _authConfig!,
      onAuthenticated: () => setState(() => _loggedIn = true),
    );
  }
}
