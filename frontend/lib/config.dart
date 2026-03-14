class AppConfig {
  // Default API base URL for local development.
  // Override via environment or settings screen in the future.
  // Points to the Caddy reverse proxy which routes /api/* to the backend
  // and /storage/* to MinIO.
  static const String defaultApiBaseUrl = 'http://localhost:2080';

  static String apiBaseUrl = defaultApiBaseUrl;
}
