import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

class OidcAuthorizationResult {
  final String code;
  final String redirectUri;

  const OidcAuthorizationResult({
    required this.code,
    required this.redirectUri,
  });
}

Future<OidcAuthorizationResult?> startOidcAuthorization({
  required Uri authorizationEndpoint,
  required String clientId,
  required String scope,
  required String codeChallenge,
  required String state,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final redirectUri = 'http://127.0.0.1:${server.port}/callback';
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

Map<String, String> oidcCallbackParams() => const {};

String oidcRedirectUri() => '';

void clearOidcCallbackUrl() {}

String _callbackHtml(bool success) {
  final title = success ? 'Login successful' : 'Login failed';
  return '<html><body><h1>$title</h1><p>You can close this tab.</p></body></html>';
}
