import 'dart:async';
import 'dart:io';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:url_launcher/url_launcher.dart';

class OidcAuthorizationResult {
  final String code;
  final String redirectUri;
  final String? codeVerifier;

  const OidcAuthorizationResult({
    required this.code,
    required this.redirectUri,
    this.codeVerifier,
  });
}

Future<OidcAuthorizationResult?> startOidcAuthorization({
  required String issuer,
  required Uri authorizationEndpoint,
  required String clientId,
  required String redirectUri,
  required String scope,
  required String codeChallenge,
  required String state,
}) async {
  if (Platform.isAndroid) {
    return _startAppAuthAuthorization(
      issuer: issuer,
      clientId: clientId,
      redirectUri: redirectUri,
      scope: scope,
    );
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  redirectUri = 'http://localhost:${server.port}/callback';
  final authUrl = authorizationEndpoint.replace(
    queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scope,
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    },
  );

  if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
    await server.close();
    return null;
  }

  try {
    final request = await server.first.timeout(const Duration(minutes: 5));
    final uri = request.requestedUri;
    final code = uri.queryParameters['code'];
    final returnedState = uri.queryParameters['state'];
    final error = uri.queryParameters['error'];

    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write(_callbackHtml(error == null && code != null));
    await request.response.close();

    if (error != null || code == null || returnedState != state) {
      return null;
    }

    return OidcAuthorizationResult(code: code, redirectUri: redirectUri);
  } on TimeoutException {
    return null;
  } finally {
    await server.close();
  }
}

Future<OidcAuthorizationResult?> _startAppAuthAuthorization({
  required String issuer,
  required String clientId,
  required String redirectUri,
  required String scope,
}) async {
  try {
    const appAuth = FlutterAppAuth();
    final result = await appAuth.authorize(
      AuthorizationRequest(
        clientId,
        redirectUri,
        issuer: issuer,
        scopes: scope.split(' '),
        allowInsecureConnections: issuer.startsWith('http://'),
      ),
    );

    final code = result.authorizationCode;
    final codeVerifier = result.codeVerifier;
    if (code == null || codeVerifier == null) {
      return null;
    }
    return OidcAuthorizationResult(
      code: code,
      redirectUri: redirectUri,
      codeVerifier: codeVerifier,
    );
  } catch (_) {
    return null;
  }
}

Map<String, String> oidcCallbackParams() => const {};

String oidcRedirectUri() => '';

void clearOidcCallbackUrl() {}

String _callbackHtml(bool success) {
  final title = success ? 'Login successful' : 'Login failed';
  return '<html><body><h1>$title</h1><p>You can close this tab.</p></body></html>';
}
