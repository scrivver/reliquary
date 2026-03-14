import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String defaultApiBaseUrl = 'http://localhost:2080';
  static const String _prefsKey = 'api_base_url';

  static String apiBaseUrl = defaultApiBaseUrl;

  /// Load the saved API base URL from shared preferences.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    apiBaseUrl = prefs.getString(_prefsKey) ?? defaultApiBaseUrl;
  }

  /// Save a new API base URL.
  static Future<void> setApiBaseUrl(String url) async {
    apiBaseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, url);
  }

  /// Reset to default.
  static Future<void> resetApiBaseUrl() async {
    apiBaseUrl = defaultApiBaseUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }
}
