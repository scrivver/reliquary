import 'package:file_picker/file_picker.dart';

import 'api_service.dart';

/// Downloads files to a user-picked directory.
/// arg1: ApiService, arg2: list of file keys.
Future<void> triggerDownload(dynamic arg1, dynamic arg2) async {
  final apiService = arg1 as ApiService;
  final keys = arg2 as List<String>;

  final dir = await FilePicker.platform.getDirectoryPath();
  if (dir == null) return;

  for (final key in keys) {
    final parts = key.split('/');
    final filename = parts.last;

    await apiService.downloadToFile(key, '$dir/$filename');
  }
}
