import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfPreviewFrame extends StatelessWidget {
  final Uint8List bytes;
  final String sourceName;

  const PdfPreviewFrame({
    super.key,
    required this.bytes,
    required this.sourceName,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: PdfViewer.data(
        bytes,
        sourceName: sourceName,
        params: const PdfViewerParams(backgroundColor: Colors.white),
      ),
    );
  }
}
