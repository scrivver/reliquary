import 'package:dio/dio.dart';

import '../config.dart';
import '../models/file_item.dart';
import 'auth_service.dart';

class ApiService {
  final AuthService _authService;
  final void Function()? onUnauthorized;
  late final Dio _dio;

  // Cache presigned URLs for 10 minutes (they're valid for 15).
  final Map<String, _CachedUrl> _urlCache = {};
  static const _cacheTtl = Duration(minutes: 10);

  ApiService(this._authService, {this.onUnauthorized}) {
    _dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl));
    _dio.interceptors.add(InterceptorsWrapper(
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
    ));
  }

  /// Upload a file through the Go backend (multipart).
  Future<String> uploadFile(
    String filename,
    List<int> bytes,
    String contentType, {
    void Function(int, int)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes,
          filename: filename,
          contentType: DioMediaType.parse(contentType)),
    });

    final response = await _dio.post(
      '/api/upload',
      data: formData,
      onSendProgress: onProgress,
    );

    return response.data['key'] as String;
  }

  /// List files with pagination.
  Future<FileListResult> listFiles({int offset = 0, int limit = 50}) async {
    final response = await _dio.get('/api/files', queryParameters: {
      'offset': offset,
      'limit': limit,
    });
    final data = response.data;
    final files = (data['files'] as List?)
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
  Future<String> presignDownload(String key) async {
    final cached = _urlCache[key];
    if (cached != null && DateTime.now().isBefore(cached.expiresAt)) {
      return cached.url;
    }

    final response =
        await _dio.get('/api/files/presign', queryParameters: {'key': key});
    final url = response.data['url'] as String;

    _urlCache[key] = _CachedUrl(url: url, expiresAt: DateTime.now().add(_cacheTtl));
    return url;
  }

  /// Delete a file from the archive.
  Future<void> deleteFile(String key) async {
    await _dio.delete('/api/files', queryParameters: {'key': key});
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
