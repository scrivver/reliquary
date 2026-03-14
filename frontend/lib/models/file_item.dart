class FileItem {
  final String key;
  final int size;
  final DateTime lastModified;
  final String thumbnailKey;

  FileItem({
    required this.key,
    required this.size,
    required this.lastModified,
    required this.thumbnailKey,
  });

  factory FileItem.fromJson(Map<String, dynamic> json) {
    return FileItem(
      key: json['key'] as String,
      size: json['size'] as int,
      lastModified: DateTime.parse(json['last_modified'] as String),
      thumbnailKey: json['thumbnail_key'] as String,
    );
  }

  String get filename => key.split('/').last;
}
