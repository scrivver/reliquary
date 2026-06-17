{ pkgs, infraShell }:

pkgs.mkShell {
  name = "reliquary-frontend-shell";
  inputsFrom = [ infraShell ];
  buildInputs = [
    pkgs.flutter
    pkgs.zenity
    pkgs.jdk17
  ];
  shellHook = ''
    export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")";
    flutter config --jdk-dir "$JAVA_HOME"
  '';

}
