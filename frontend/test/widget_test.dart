import 'package:flutter_test/flutter_test.dart';

import 'package:reliquary_fe/models/file_item.dart';
import 'package:reliquary_fe/main.dart';

void main() {
  test('App title is stable', () {
    expect(appTitle, 'Reliquary');
  });

  test('FileItem displayPath keeps uploaded folder structure', () {
    final file = FileItem(
      key: 'files/alice/2026/06/Photos/Trip/image.jpg',
      size: 100,
      contentType: 'image/jpeg',
      lastModified: DateTime.utc(2026, 6, 18),
    );

    expect(file.displayPath, 'Photos/Trip/image.jpg');
    expect(file.filename, 'image.jpg');
  });
}
