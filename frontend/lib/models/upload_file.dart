import 'dart:typed_data';

/// Represents a file selected for upload, with optional relative path
/// for folder uploads. Avoids using PlatformFile.path which breaks on web.
class UploadFile {
  final String name;
  final int size;
  final Uint8List? bytes;
  final String? filePath; // filesystem path for native
  final String? relativePath; // folder-relative path (e.g., "Photos/img.jpg")

  UploadFile({
    required this.name,
    required this.size,
    this.bytes,
    this.filePath,
    this.relativePath,
  });

  String get displayName => relativePath ?? name;
}
