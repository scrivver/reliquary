import 'dart:io';

bool get isNativeRuntime =>
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isLinux ||
    Platform.isMacOS ||
    Platform.isWindows;
