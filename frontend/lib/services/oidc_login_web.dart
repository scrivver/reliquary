// ignore_for_file: avoid_web_libraries_in_flutter, use_null_aware_elements

// ignore: deprecated_member_use
import 'dart:html' as html;

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
  redirectUri = oidcRedirectUri();
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

  await launchUrl(authUrl, webOnlyWindowName: '_self');
  return null;
}

Map<String, String> oidcCallbackParams() {
  final uri = Uri.base;
  final code = uri.queryParameters['code'];
  final state = uri.queryParameters['state'];
  final error = uri.queryParameters['error'];
  if (code == null && state == null && error == null) {
    return const {};
  }
  return {
    if (code != null) 'code': code,
    if (state != null) 'state': state,
    if (error != null) 'error': error,
  };
}

String oidcRedirectUri() {
  return '${Uri.base.origin}/callback';
}

void clearOidcCallbackUrl() {
  html.window.history.replaceState(null, '', Uri.base.origin);
}
