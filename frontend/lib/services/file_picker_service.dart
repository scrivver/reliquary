import '../models/upload_file.dart';

import 'file_picker_native.dart' if (dart.library.js_interop) 'file_picker_web.dart'
    as platform;

/// Cross-platform file picker.
Future<List<UploadFile>?> pickFiles({bool allowMultiple = true}) {
  return platform.pickFilesPlatform(allowMultiple: allowMultiple);
}

/// Cross-platform folder picker.
Future<List<UploadFile>?> pickFolder() {
  return platform.pickFolderPlatform();
}
