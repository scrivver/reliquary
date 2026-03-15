import 'package:file_picker/file_picker.dart';

import 'file_picker_native.dart' if (dart.library.js_interop) 'file_picker_web.dart'
    as platform;

/// Cross-platform file picker that uses a reliable HTML implementation
/// on web and the file_picker package on native platforms.
Future<FilePickerResult?> pickFiles({bool allowMultiple = true}) {
  return platform.pickFilesPlatform(allowMultiple: allowMultiple);
}
