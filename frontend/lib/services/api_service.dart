import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config.dart';
import '../models/file_item.dart';
import 'auth_service.dart';

class ApiService {
  final AuthService _authService;
  final void Function()? onUnauthorized;
  late final Dio _dio;
  late final String _origin;

  // Presigned URLs are valid for 15 minutes; cache them for 10.
  final Map<String, _CachedUrl> _urlCache = {};
  // In-memory byte cache for previews so thumbnails are not re-downloaded.
  final Map<String, _CachedBytes> _bytesCache = {};
  static const _cacheTtl = Duration(minutes: 10);

  ApiService(this._authService, {this.onUnauthorized}) {
    _origin = Uri.parse(AppConfig.apiBaseUrl).origin;
    _dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl));
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _authService.getToken();
          if (token != null) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401) {
            await _authService.logout();
            onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );
  }

  /// Upload a file through the Go backend (multipart).
  /// Returns the key and whether it was a duplicate.
  Future<({String key, bool duplicate, String? warning})> uploadFile(
    String filename,
    List<int> bytes,
    String contentType, {
    String? relativePath,
    void Function(int, int)? onProgress,
  }) async {
    final map = <String, dynamic>{
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: DioMediaType.parse(contentType),
      ),
    };
    if (relativePath != null) {
      map['path'] = relativePath;
    }
    final formData = FormData.fromMap(map);

    final response = await _dio.post(
      '/api/upload',
      data: formData,
      onSendProgress: onProgress,
    );

    return (
      key: response.data['key'] as String,
      duplicate: response.data['duplicate'] == true,
      warning: response.data['warning'] as String?,
    );
  }

  /// List files with pagination.
  Future<FileListResult> listFiles({int offset = 0, int limit = 50}) async {
    final response = await _dio.get(
      '/api/files',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    final data = response.data;
    final files =
        (data['files'] as List?)
            ?.map((f) => FileItem.fromJson(f as Map<String, dynamic>))
            .toList() ??
        [];
    return FileListResult(
      files: files,
      totalCount: data['total_count'] as int,
      offset: data['offset'] as int,
      limit: data['limit'] as int,
    );
  }

  /// Get a presigned download URL for a file or thumbnail.
  /// Results are cached for 10 minutes to avoid redundant API calls.
  Future<String> presignDownload(String key, {bool forceDownload = false}) async {
    final cacheKey = (forceDownload ? 'download:' : '') + key;
    final cached = _urlCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }

    final response = await _dio.get(
      '/api/files/presign',
      queryParameters: {'key': key, if (forceDownload) 'download': 'true'},
    );
    final relativePath = response.data['url'] as String;
    final url = _origin + relativePath;

    _urlCache[cacheKey] = _CachedUrl(
      url: url,
      expiresAt: DateTime.now().add(_cacheTtl),
    );
    return url;
  }

  /// Fetch the raw bytes of a file or thumbnail.
  ///
  /// The request carries the Authorization header and is validated by Caddy's
  /// forward_auth against [AuthCheck] before the bytes are streamed from
  /// MinIO. Used for in-app previews; results are cached briefly.
  Future<Uint8List> fetchContent(String key, {bool download = false}) async {
    final cacheKey = (download ? 'download:' : '') + key;
    final cached = _bytesCache[cacheKey];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.bytes;
    }

    final url = await presignDownload(key, forceDownload: download);
    final response = await _dio.getUri(
      Uri.parse(url),
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = Uint8List.fromList(response.data as List<int>);

    _bytesCache[cacheKey] = _CachedBytes(
      bytes: bytes,
      expiresAt: DateTime.now().add(_cacheTtl),
    );
    return bytes;
  }

  /// Save a single file to a local path (native).
  ///
  /// Streams through dio so the Authorization header is sent and the request
  /// is validated at the proxy edge before MinIO serves the bytes.
  Future<void> downloadToFile(String key, String savePath) async {
    final url = await presignDownload(key, forceDownload: true);
    await _dio.downloadUri(Uri.parse(url), savePath);
  }

  /// Delete an active file.
  Future<void> deleteFile(String key) async {
    await _dio.delete('/api/files', queryParameters: {'key': key});
  }

  /// Download multiple files as a zip archive. Returns the zip bytes.
  Future<List<int>> batchDownload(List<String> keys) async {
    final response = await _dio.post(
      '/api/files/download',
      data: {'keys': keys},
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data as List<int>;
  }

  // --- Stats API ---

  /// Get storage analytics for the current user.
  Future<Map<String, dynamic>> getStats() async {
    final response = await _dio.get('/api/stats');
    return response.data as Map<String, dynamic>;
  }

  // --- Admin API ---

  /// List all users (admin only).
  Future<List<Map<String, dynamic>>> listUsers() async {
    final response = await _dio.get('/api/admin/users');
    return (response.data as List).cast<Map<String, dynamic>>();
  }

  /// Create a new user (admin only).
  Future<void> createUser(String username, String password) async {
    await _dio.post(
      '/api/admin/users',
      data: {'username': username, 'password': password},
    );
  }

  /// Delete a user (admin only).
  Future<void> deleteUser(String username, {bool permanent = false}) async {
    await _dio.delete(
      '/api/admin/users/$username',
      queryParameters: permanent ? {'permanent': 'true'} : null,
    );
  }

  /// Re-enable a deactivated user.
  Future<void> activateUser(String username) async {
    await _dio.put('/api/admin/users/$username/activate');
  }

  /// Change a user's password.
  Future<void> changePassword(String username, String newPassword) async {
    await _dio.put(
      '/api/admin/users/$username/password',
      data: {'password': newPassword},
    );
  }
}

class FileListResult {
  final List<FileItem> files;
  final int totalCount;
  final int offset;
  final int limit;

  FileListResult({
    required this.files,
    required this.totalCount,
    required this.offset,
    required this.limit,
  });

  bool get hasMore => offset + files.length < totalCount;
}

class _CachedUrl {
  final String url;
  final DateTime expiresAt;

  _CachedUrl({required this.url, required this.expiresAt});
}

class _CachedBytes {
  final Uint8List bytes;
  final DateTime expiresAt;

  _CachedBytes({required this.bytes, required this.expiresAt});
}
