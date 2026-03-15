import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

import '../models/upload_file.dart';

/// Reliable web file picker using the HTML file input directly.
Future<List<UploadFile>?> pickFilesPlatform({bool allowMultiple = true}) async {
  return _pick(allowMultiple: allowMultiple, directory: false);
}

/// Web folder picker using webkitdirectory.
Future<List<UploadFile>?> pickFolderPlatform() async {
  return _pick(allowMultiple: true, directory: true);
}

Future<List<UploadFile>?> _pick({
  required bool allowMultiple,
  required bool directory,
}) async {
  final completer = Completer<List<UploadFile>?>();

  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = allowMultiple
    ..style.display = 'none';

  if (directory) {
    input.setAttribute('webkitdirectory', '');
  }

  input.onChange.listen((event) async {
    final files = input.files;
    if (files == null || files.length == 0) {
      if (!completer.isCompleted) completer.complete(null);
      input.remove();
      return;
    }

    final uploadFiles = <UploadFile>[];

    for (var i = 0; i < files.length; i++) {
      final file = files.item(i)!;
      final bytes = await _readFileBytes(file);
      final relativePath = file.webkitRelativePath;

      uploadFiles.add(UploadFile(
        name: file.name,
        size: file.size,
        bytes: bytes,
        relativePath: relativePath.isNotEmpty ? relativePath : null,
      ));
    }

    if (!completer.isCompleted) {
      completer.complete(uploadFiles);
    }
    input.remove();
  });

  web.document.body!.append(input);
  input.click();

  return completer.future;
}

Future<Uint8List> _readFileBytes(web.File file) async {
  final completer = Completer<Uint8List>();
  final reader = web.FileReader();

  reader.onLoadEnd.listen((_) {
    final result = reader.result;
    if (result != null) {
      final arrayBuffer = result as JSArrayBuffer;
      final bytes = arrayBuffer.toDart.asUint8List();
      completer.complete(bytes);
    } else {
      completer.complete(Uint8List(0));
    }
  });

  reader.readAsArrayBuffer(file);
  return completer.future;
}
