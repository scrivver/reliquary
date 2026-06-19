import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String _fallbackApiBaseUrl = 'https://reliquary.chunhou20c.dev';
  static const String _configuredDefaultApiBaseUrl = String.fromEnvironment(
    'RELIQUARY_DEFAULT_API_BASE_URL',
  );
  static const String _prefsKey = 'api_base_url';

  static String apiBaseUrl = defaultApiBaseUrl;
  static bool hasSavedApiBaseUrl = false;

  static String get defaultApiBaseUrl {
    if (_configuredDefaultApiBaseUrl.isNotEmpty) {
      return _configuredDefaultApiBaseUrl;
    }

    final base = Uri.base;
    if ((base.scheme == 'http' || base.scheme == 'https') &&
        base.host.isNotEmpty) {
      return base.origin;
    }

    return _fallbackApiBaseUrl;
  }

  /// Load the saved API base URL from shared preferences.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final shouldIgnoreSavedDevOrigin =
        saved != null &&
        _configuredDefaultApiBaseUrl.isNotEmpty &&
        saved == Uri.base.origin &&
        saved != defaultApiBaseUrl;
    hasSavedApiBaseUrl =
        saved != null && saved.isNotEmpty && !shouldIgnoreSavedDevOrigin;
    apiBaseUrl = hasSavedApiBaseUrl ? saved! : defaultApiBaseUrl;
  }

  /// Save a new API base URL.
  static Future<void> setApiBaseUrl(String url) async {
    apiBaseUrl = normalizeBaseUrl(url);
    hasSavedApiBaseUrl = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, apiBaseUrl);
  }

  /// Reset to default.
  static Future<void> resetApiBaseUrl() async {
    apiBaseUrl = defaultApiBaseUrl;
    hasSavedApiBaseUrl = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
  }

  static String normalizeBaseUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}
