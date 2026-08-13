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

const _sessionExpiredNotice = 'Your session expired. Please sign in again.';

/// Guards against a burst of navigations. A screen typically has several
/// requests in flight, and an expired token fails all of them at once.
bool _returningToAuthGate = false;

/// Tears the app back down to [AuthGate], which re-checks the stored session
/// and lands on the login screen when there is nothing valid left.
///
/// The caller is responsible for clearing the session first; this only moves
/// the user. Pass [notice] to explain an involuntary sign-out.
void returnToAuthGate({String? notice}) {
  if (_returningToAuthGate) return;
  final nav = navigatorKey.currentState;
  if (nav == null) return;

  _returningToAuthGate = true;
  nav.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => AuthGate(notice: notice)),
    (_) => false,
  );
}

/// Ends a session the server has stopped accepting. Reached when a token
/// expires mid-use, and when one is revoked by a password change or a
/// deactivation, since the backend rejects those the same way.
void handleSessionExpired() => returnToAuthGate(notice: _sessionExpiredNotice);

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
  /// Message shown on the login screen, explaining an involuntary sign-out.
  final String? notice;

  const AuthGate({super.key, this.notice});

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
    // The gate is mounted, so the navigation that brought us here is done and
    // a later expiry is free to move the user again.
    _returningToAuthGate = false;
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
      notice: widget.notice,
      onAuthenticated: () => setState(() => _loggedIn = true),
    );
  }
}
