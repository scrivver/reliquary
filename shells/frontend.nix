{ pkgs, infraShell }:

pkgs.mkShell {
  name = "reliquary-frontend-shell";
  inputsFrom = [ infraShell ];
  buildInputs = [
    pkgs.flutter
  ];
}
