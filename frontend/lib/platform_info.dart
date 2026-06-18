import 'package:flutter/foundation.dart';

import 'platform_info_stub.dart' if (dart.library.io) 'platform_info_io.dart';

bool get isWebBuild => kIsWeb;

bool get requiresConfiguredServerUrl => !isWebBuild && isNativeRuntime;
