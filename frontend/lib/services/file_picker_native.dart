import 'package:file_picker/file_picker.dart';

/// Native file picker — delegates to the file_picker package.
Future<FilePickerResult?> pickFilesPlatform({bool allowMultiple = true}) async {
  return FilePicker.platform.pickFiles(
    allowMultiple: allowMultiple,
    type: FileType.any,
  );
}
