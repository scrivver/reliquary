import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfPreviewFrame extends StatelessWidget {
  final String url;

  const PdfPreviewFrame({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: PdfViewer.uri(
        Uri.parse(url),
        params: const PdfViewerParams(backgroundColor: Colors.white),
      ),
    );
  }
}
