import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models/auth_config.dart';
import 'oidc_login.dart';

class AuthService {
  static const _tokenKey = 'jwt_token';
  static const _usernameKey = 'username';
  static const _roleKey = 'role';
  static const _providerKey = 'auth_provider';
  static const _refreshTokenKey = 'oidc_refresh_token';
  static const _idTokenKey = 'oidc_id_token';
  static const _oidcStateKey = 'oidc_state';
  static const _oidcVerifierKey = 'oidc_code_verifier';
  static const _oidcIssuerKey = 'oidc_issuer';
  static const _oidcClientIdKey = 'oidc_client_id';

  final Dio _dio = Dio();
  final Map<String, Map<String, dynamic>> _discoveryCache = {};

  /// Check the server's auth capabilities.
  Future<AuthConfig> getAuthConfig({String? baseUrl}) async {
    final root = AppConfig.normalizeBaseUrl(baseUrl ?? AppConfig.apiBaseUrl);
    final response = await _dio.get('$root/api/auth/config');
    return AuthConfig.fromJson((response.data as Map).cast<String, dynamic>());
  }

  /// Backward-compatible auth mode probe for older callers.
  Future<String> getAuthMode() async {
    try {
      final config = await getAuthConfig();
      if (config.none.enabled) return 'none';
      if (config.proxy.enabled && !config.hasInteractiveLogin) return 'proxy';
      if (config.password.enabled) return 'full';
      if (config.oidc.enabled) return 'oidc';
      return 'full';
    } catch (_) {
      return 'full';
    }
  }

  Future<bool> login(String username, String password) async {
    try {
      final response = await _dio.post(
        '${AppConfig.apiBaseUrl}/api/login',
        data: {'username': username, 'password': password},
      );

      final token = response.data['token'] as String;
      final respUsername = response.data['username'] as String;
      final respRole = response.data['role'] as String;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      await prefs.setString(_usernameKey, respUsername);
      await prefs.setString(_roleKey, respRole);
      await prefs.setString(_providerKey, 'password');
      await prefs.remove(_refreshTokenKey);
      await prefs.remove(_idTokenKey);
      return true;
    } on DioException {
      return false;
    }
  }

  Future<bool> loginWithOidc(OidcAuthConfig oidc) async {
    if (!oidc.enabled || oidc.issuerUrl.isEmpty || oidc.clientId.isEmpty) {
      return false;
    }

    try {
      final discovery = await _discover(oidc.issuerUrl);
      final authorizationEndpoint = Uri.parse(
        discovery['authorization_endpoint'] as String,
      );
      final codeVerifier = _generateCodeVerifier();
      final codeChallenge = _generateCodeChallenge(codeVerifier);
      final state = _generateState();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_oidcStateKey, state);
      await prefs.setString(_oidcVerifierKey, codeVerifier);
      await prefs.setString(_oidcIssuerKey, oidc.issuerUrl);
      await prefs.setString(_oidcClientIdKey, oidc.clientId);

      final result = await startOidcAuthorization(
        issuer: oidc.issuerUrl,
        authorizationEndpoint: authorizationEndpoint,
        clientId: oidc.clientId,
        redirectUri: oidc.redirectUri,
        scope: 'openid profile email offline_access',
        codeChallenge: codeChallenge,
        state: state,
      );

      if (result == null) {
        return false;
      }

      return _exchangeOidcCode(
        issuer: oidc.issuerUrl,
        clientId: oidc.clientId,
        code: result.code,
        redirectUri: result.redirectUri,
        codeVerifier: result.codeVerifier ?? codeVerifier,
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> completeOidcRedirectIfPresent(OidcAuthConfig oidc) async {
    final params = oidcCallbackParams();
    if (params.isEmpty) return false;

    try {
      final prefs = await SharedPreferences.getInstance();
      final expectedState = prefs.getString(_oidcStateKey);
      final codeVerifier = prefs.getString(_oidcVerifierKey);
      final issuer = prefs.getString(_oidcIssuerKey) ?? oidc.issuerUrl;
      final clientId = prefs.getString(_oidcClientIdKey) ?? oidc.clientId;
      final code = params['code'];
      final returnedState = params['state'];

      if (params['error'] != null ||
          code == null ||
          codeVerifier == null ||
          returnedState == null ||
          returnedState != expectedState) {
        clearOidcCallbackUrl();
        return false;
      }

      final ok = await _exchangeOidcCode(
        issuer: issuer,
        clientId: clientId,
        code: code,
        redirectUri: oidcRedirectUri(),
        codeVerifier: codeVerifier,
      );
      clearOidcCallbackUrl();
      return ok;
    } catch (_) {
      clearOidcCallbackUrl();
      return false;
    }
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    if (token != null) return token;
    if (await _refreshOidcToken()) {
      return prefs.getString(_tokenKey);
    }
    return null;
  }

  Future<String?> getUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  Future<String?> getRole() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_roleKey);
  }

  Future<String?> getProvider() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_providerKey);
  }

  Future<bool> isAdmin() async {
    final role = await getRole();
    return role == 'admin';
  }

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_roleKey);
    await prefs.remove(_providerKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_idTokenKey);
    await prefs.remove(_oidcStateKey);
    await prefs.remove(_oidcVerifierKey);
    await prefs.remove(_oidcIssuerKey);
    await prefs.remove(_oidcClientIdKey);
  }

  Future<Map<String, dynamic>> _discover(String issuer) async {
    final cached = _discoveryCache[issuer];
    if (cached != null) return cached;

    final response = await _dio.get(
      '${AppConfig.apiBaseUrl}/api/auth/oidc/discovery',
    );
    final data = (response.data as Map).cast<String, dynamic>();
    _discoveryCache[issuer] = data;
    return data;
  }

  Future<bool> _exchangeOidcCode({
    required String issuer,
    required String clientId,
    required String code,
    required String redirectUri,
    required String codeVerifier,
  }) async {
    final response = await _dio.post(
      '${AppConfig.apiBaseUrl}/api/auth/oidc/token',
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': codeVerifier,
      },
    );

    await _storeOidcTokens(
      (response.data as Map).cast<String, dynamic>(),
      issuer: issuer,
    );
    return true;
  }

  Future<bool> _refreshOidcToken() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString(_providerKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    final issuer = prefs.getString(_oidcIssuerKey);
    final clientId = prefs.getString(_oidcClientIdKey);
    if (provider != 'oidc' ||
        refreshToken == null ||
        issuer == null ||
        clientId == null) {
      return false;
    }

    try {
      final response = await _dio.post(
        '${AppConfig.apiBaseUrl}/api/auth/oidc/token',
        data: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
      );

      await _storeOidcTokens(
        (response.data as Map).cast<String, dynamic>(),
        issuer: issuer,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _storeOidcTokens(
    Map<String, dynamic> tokens, {
    required String issuer,
  }) async {
    final accessToken = tokens['access_token'] as String?;
    if (accessToken == null) {
      throw StateError('OIDC token response did not include access_token');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, accessToken);
    await prefs.setString(_providerKey, 'oidc');
    await prefs.setString(_roleKey, 'user');
    await prefs.setString(_oidcIssuerKey, issuer);

    final refreshToken = tokens['refresh_token'] as String?;
    final idToken = tokens['id_token'] as String?;
    if (refreshToken != null) {
      await prefs.setString(_refreshTokenKey, refreshToken);
    }
    if (idToken != null) {
      await prefs.setString(_idTokenKey, idToken);
    }

    final username = tokens['username'] as String?;
    if (username != null && username.isNotEmpty) {
      await prefs.setString(_usernameKey, username);
    }
  }

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  String _generateState() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
