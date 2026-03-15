import 'download_helper_native.dart'
    if (dart.library.js_interop) 'download_helper_web.dart' as platform;

/// Cross-platform download trigger.
Future<void> triggerDownload(dynamic arg1, dynamic arg2) {
  return platform.triggerDownload(arg1, arg2);
}
