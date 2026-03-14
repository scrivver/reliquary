import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class AuthService {
  static const _tokenKey = 'jwt_token';
  final Dio _dio = Dio();

  String? _cachedToken;

  Future<bool> login(String username, String password) async {
    try {
      final response = await _dio.post(
        '${AppConfig.apiBaseUrl}/api/login',
        data: {'username': username, 'password': password},
      );

      final token = response.data['token'] as String;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, token);
      _cachedToken = token;
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

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    return token != null;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    _cachedToken = null;
  }
}
