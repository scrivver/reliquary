class AuthConfig {
  final PasswordAuthConfig password;
  final OidcAuthConfig oidc;
  final ProxyAuthConfig proxy;
  final NoneAuthConfig none;

  const AuthConfig({
    required this.password,
    required this.oidc,
    required this.proxy,
    required this.none,
  });

  factory AuthConfig.fromJson(Map<String, dynamic> json) {
    return AuthConfig(
      password: PasswordAuthConfig.fromJson(
        (json['password'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      oidc: OidcAuthConfig.fromJson(
        (json['oidc'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      proxy: ProxyAuthConfig.fromJson(
        (json['proxy'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      none: NoneAuthConfig.fromJson(
        (json['none'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  bool get hasInteractiveLogin => password.enabled || oidc.enabled;
}

class PasswordAuthConfig {
  final bool enabled;

  const PasswordAuthConfig({required this.enabled});

  factory PasswordAuthConfig.fromJson(Map<String, dynamic> json) {
    return PasswordAuthConfig(enabled: json['enabled'] == true);
  }
}

class OidcAuthConfig {
  final bool enabled;
  final String issuerUrl;
  final String clientId;
  final String usernameClaim;

  const OidcAuthConfig({
    required this.enabled,
    required this.issuerUrl,
    required this.clientId,
    required this.usernameClaim,
  });

  factory OidcAuthConfig.fromJson(Map<String, dynamic> json) {
    return OidcAuthConfig(
      enabled: json['enabled'] == true,
      issuerUrl: (json['issuer_url'] as String?) ?? '',
      clientId: (json['client_id'] as String?) ?? '',
      usernameClaim:
          (json['username_claim'] as String?) ?? 'preferred_username',
    );
  }
}

class ProxyAuthConfig {
  final bool enabled;
  final bool legacy;

  const ProxyAuthConfig({required this.enabled, required this.legacy});

  factory ProxyAuthConfig.fromJson(Map<String, dynamic> json) {
    return ProxyAuthConfig(
      enabled: json['enabled'] == true,
      legacy: json['legacy'] == true,
    );
  }
}

class NoneAuthConfig {
  final bool enabled;

  const NoneAuthConfig({required this.enabled});

  factory NoneAuthConfig.fromJson(Map<String, dynamic> json) {
    return NoneAuthConfig(enabled: json['enabled'] == true);
  }
}
