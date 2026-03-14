{ pkgs, infraShell }:

pkgs.mkShell {
  name = "reliquary-frontend-shell";
  inputsFrom = [ infraShell ];
  nativeBuildInputs = [
    pkgs.pkg-config
  ];
  buildInputs = [
    pkgs.flutter
    pkgs.libsecret
  ];
}
