{ pkgs }:

pkgs.flutter.buildFlutterApplication {
  pname = "reliquary-frontend-web";
  version = "0.1.0";

  src = ../frontend;
  targetFlutterPlatform = "web";
  pubspecLock = pkgs.lib.importJSON ../frontend/pubspec.lock.json;

  # The nixpkgs pdfrx source builder patches Linux PDFium paths, but the web
  # build only needs the Dart/web package sources. pdfium_flutter 0.2.2 also
  # lacks the linux/CMakeLists.txt layout expected by that patch path.
  customSourceBuilders = {
    pdfrx = { src, ... }: src;
    pdfium_flutter = { src, ... }: src;
  };
}
