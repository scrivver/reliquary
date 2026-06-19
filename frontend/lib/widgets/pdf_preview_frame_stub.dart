import 'package:flutter/material.dart';

class PdfPreviewFrame extends StatelessWidget {
  final String url;

  const PdfPreviewFrame({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'PDF preview is available in the web app.',
        style: TextStyle(color: Colors.white),
      ),
    );
  }
}
