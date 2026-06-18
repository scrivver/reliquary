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
  return null;
}

Map<String, String> oidcCallbackParams() => const {};

String oidcRedirectUri() => '';

void clearOidcCallbackUrl() {}
