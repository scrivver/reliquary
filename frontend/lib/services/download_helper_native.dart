import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';

/// Downloads files to a user-picked directory.
/// arg1: List of String keys, arg2: Future Function(String) urlResolver
Future<void> triggerDownload(dynamic arg1, dynamic arg2) async {
  final keys = arg1 as List<String>;
  final urlResolver = arg2 as Future<String> Function(String);

  final dir = await FilePicker.platform.getDirectoryPath();
  if (dir == null) return;

  final dio = Dio();

  for (final key in keys) {
    final url = await urlResolver(key);
    final parts = key.split('/');
    final filename = parts.last;

    await dio.download(url, '$dir/$filename');
  }
}
