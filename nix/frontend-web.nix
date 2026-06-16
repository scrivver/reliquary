{ pkgs }:

pkgs.flutter.buildFlutterApplication {
  pname = "reliquary-frontend-web";
  version = "0.1.0";

  src = ../frontend;
  targetFlutterPlatform = "web";
  pubspecLock = pkgs.lib.importJSON ../frontend/pubspec.lock.json;
}
