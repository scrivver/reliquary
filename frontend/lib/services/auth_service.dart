import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class AuthService {
  static const _tokenKey = 'jwt_token';
  static const _usernameKey = 'username';
  static const _roleKey = 'role';
  final Dio _dio = Dio();

  String? _cachedToken;
  String? _cachedUsername;
  String? _cachedRole;

  /// Check the server's auth mode. Returns "full", "proxy", or "none".
  Future<String> getAuthMode() async {
    try {
      final response = await _dio.get('${AppConfig.apiBaseUrl}/api/health');
      return (response.data['auth_mode'] as String?) ?? 'full';
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

      _cachedToken = token;
      _cachedUsername = respUsername;
      _cachedRole = respRole;
      return true;
    } on DioException {
      return false;
    }
  }

  Future<String?> getToken() async {
    if (_cachedToken == null) {
      final prefs = await SharedPreferences.getInstance();
      _cachedToken = prefs.getString(_tokenKey);
    }
    return _cachedToken;
  }

  Future<String?> getUsername() async {
    if (_cachedUsername == null) {
      final prefs = await SharedPreferences.getInstance();
      _cachedUsername = prefs.getString(_usernameKey);
    }
    return _cachedUsername;
  }

  Future<String?> getRole() async {
    if (_cachedRole == null) {
      final prefs = await SharedPreferences.getInstance();
      _cachedRole = prefs.getString(_roleKey);
    }
    return _cachedRole;
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
    _cachedToken = null;
    _cachedUsername = null;
    _cachedRole = null;
  }
}
