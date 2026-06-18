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
  return null;
}

Map<String, String> oidcCallbackParams() => const {};

String oidcRedirectUri() => '';

void clearOidcCallbackUrl() {}
