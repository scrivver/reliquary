{ pkgs, processComposeConfig }:

pkgs.mkShell {
  name = "reliquary-infra-shell";
  buildInputs = [
    pkgs.minio
    pkgs.caddy
    pkgs.process-compose
    pkgs.python3
    pkgs.curl
    pkgs.nodejs_24
  ];

  shellHook = ''
    export SHELL=${pkgs.bash}/bin/bash
    export PATH="$PWD/bin:$PATH"

    export DATA_DIR="$PWD/.data"
    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/minio"

    export MINIO_PATH="$DATA_DIR/minio"

    # Generate process-compose config
    cp -f ${processComposeConfig} "$DATA_DIR/process-compose.yaml"

    # Process-compose unix socket path
    export PC_SOCKET="$DATA_DIR/process-compose.sock"

    # Export port file paths so other services can read the dynamic ports
    export MINIO_PORT_FILE="$DATA_DIR/minio/port"
    export MINIO_CONSOLE_PORT_FILE="$DATA_DIR/minio/console_port"
    export PROXY_PORT_FILE="$DATA_DIR/caddy/port"
  '';
}
