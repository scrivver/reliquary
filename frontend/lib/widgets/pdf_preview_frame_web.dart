import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

class PdfPreviewFrame extends StatefulWidget {
  final String url;

  const PdfPreviewFrame({super.key, required this.url});

  @override
  State<PdfPreviewFrame> createState() => _PdfPreviewFrameState();
}

class _PdfPreviewFrameState extends State<PdfPreviewFrame> {
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType =
        'pdf-preview-${widget.url.hashCode}-${DateTime.now().microsecondsSinceEpoch}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      return web.HTMLIFrameElement()
        ..src = widget.url
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = 'white';
    });
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
