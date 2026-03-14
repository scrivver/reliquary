import 'package:dio/dio.dart';

import '../config.dart';
import '../models/file_item.dart';
import 'auth_service.dart';

class ApiService {
  final AuthService _authService;
  late final Dio _dio;

  ApiService(this._authService) {
    _dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _authService.getToken();
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
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
      'file': MultipartFile.fromBytes(bytes, filename: filename, contentType: DioMediaType.parse(contentType)),
    });

    final response = await _dio.post(
      '/api/upload',
      data: formData,
      onSendProgress: onProgress,
    );

    return response.data['key'] as String;
  }

  /// List all files in the archive.
  Future<List<FileItem>> listFiles() async {
    final response = await _dio.get('/api/files');
    final files = (response.data['files'] as List?)
            ?.map((f) => FileItem.fromJson(f as Map<String, dynamic>))
            .toList() ??
        [];
    return files;
  }

  /// Get a presigned download URL for a file or thumbnail.
  Future<String> presignDownload(String key) async {
    final response =
        await _dio.get('/api/files/presign', queryParameters: {'key': key});
    return response.data['url'] as String;
  }

  /// Delete a file from the archive.
  Future<void> deleteFile(String key) async {
    await _dio.delete('/api/files', queryParameters: {'key': key});
  }
}
