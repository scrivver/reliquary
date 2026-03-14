class FileItem {
  final String key;
  final int size;
  final String contentType;
  final DateTime lastModified;
  final String? thumbnailKey;

  FileItem({
    required this.key,
    required this.size,
    required this.contentType,
    required this.lastModified,
    this.thumbnailKey,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      key: json['key'] as String,
      size: (json['size'] as num).toInt(),
      contentType: (json['content_type'] as String?) ?? 'application/octet-stream',
      lastModified: DateTime.parse(json['last_modified'] as String),
      thumbnailKey: json['thumbnail_key'] as String?,
    );
  }

  String get filename => key.split('/').last;

  bool get isImage => contentType.startsWith('image/');
}
