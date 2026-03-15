{ pkgs, bucketName ? "reliquary" }:
{
  processes = {
    minio = {
      command = pkgs.writeShellScript "start-minio" ''
        set -euo pipefail
        mkdir -p "$DATA_DIR/minio/data"
        rm -f "$DATA_DIR/minio/port" "$DATA_DIR/minio/console_port"

        # Pick two ephemeral ports — API and Console
        PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
        CONSOLE_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
        echo "$PORT" > "$DATA_DIR/minio/port"
        echo "$CONSOLE_PORT" > "$DATA_DIR/minio/console_port"

        export MINIO_ROOT_USER=minioadmin
        export MINIO_ROOT_PASSWORD=minioadmin

        exec ${pkgs.minio}/bin/minio server \
          --address "127.0.0.1:$PORT" \
          --console-address "127.0.0.1:$CONSOLE_PORT" \
          "$DATA_DIR/minio/data"
      '';
      readiness_probe = {
        exec.command = pkgs.writeShellScript "minio-ready" ''
          PORT=$(cat "$DATA_DIR/minio/port" 2>/dev/null) || exit 1
          curl -sf "http://127.0.0.1:$PORT/minio/health/live" -o /dev/null 2>&1
        '';
        initial_delay_seconds = 3;
        period_seconds = 2;
      };
    };

    minio-create-bucket = {
      command = pkgs.writeShellScript "minio-create-bucket" ''
        PORT=$(cat "$DATA_DIR/minio/port")
        ${pkgs.minio-client}/bin/mc alias set local "http://127.0.0.1:$PORT" minioadmin minioadmin --api S3v4
        ${pkgs.minio-client}/bin/mc mb --ignore-existing local/${bucketName}
        ${pkgs.minio-client}/bin/mc anonymous set download local/${bucketName}
      '';
      depends_on = {
        minio.condition = "process_healthy";
      };
      availability = {
        restart = "no";
      };
    };
  };

  inherit bucketName;
}

