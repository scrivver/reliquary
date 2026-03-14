{ pkgs, infraShell }:

pkgs.mkShell {
  name = "reliquary-backend-shell";
  inputsFrom = [ infraShell ];
  buildInputs = [
    pkgs.go
    pkgs.gopls
    pkgs.gotools
  ];
}
