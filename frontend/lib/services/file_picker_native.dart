import 'dart:io';
import 'package:file_picker/file_picker.dart';

import '../models/upload_file.dart';

/// Native file picker — delegates to the file_picker package.
Future<List<UploadFile>?> pickFilesPlatform({bool allowMultiple = true}) async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: allowMultiple,
    type: FileType.any,
  );
  if (result == null || result.files.isEmpty) return null;

  return result.files.map((f) => UploadFile(
    name: f.name,
    size: f.size,
    filePath: f.path,
  )).toList();
}

/// Native folder picker — picks a directory and lists all files recursively.
Future<List<UploadFile>?> pickFolderPlatform() async {
  final dirPath = await FilePicker.platform.getDirectoryPath();
  if (dirPath == null) return null;

  final dir = Directory(dirPath);
  final dirName = dirPath.split(Platform.pathSeparator).last;
  final files = <UploadFile>[];

  await for (final entity in dir.list(recursive: true)) {
    if (entity is File) {
      final stat = await entity.stat();
      final relativePath = entity.path.substring(dirPath.length + 1);
      files.add(UploadFile(
        name: entity.path.split(Platform.pathSeparator).last,
        size: stat.size,
        filePath: entity.path,
        relativePath: '$dirName/$relativePath',
      ));
    }
  }

  if (files.isEmpty) return null;
  return files;
}
