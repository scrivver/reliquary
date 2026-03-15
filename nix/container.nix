{ pkgs }:

let
  backend = import ./backend.nix { inherit pkgs; };

  caddyfile = pkgs.writeText "Caddyfile" ''
    {
      admin off
    }

    :2080 {
      header Access-Control-Allow-Origin *
      header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
      header Access-Control-Allow-Headers "Accept, Authorization, Content-Type"

      @options method OPTIONS
      handle @options {
        respond 204
      }

      handle /api/* {
        reverse_proxy unix//run/reliquary/backend.sock
      }

      handle /storage/* {
        uri strip_prefix /storage
        reverse_proxy 127.0.0.1:9000 {
          header_up Host 127.0.0.1:9000
          header_down -Access-Control-Allow-Origin
          header_down -Access-Control-Allow-Methods
          header_down -Access-Control-Allow-Headers
        }
      }

      handle {
        root * /srv/web
        file_server
        try_files {path} /index.html
      }
    }
  '';

  entrypoint = pkgs.writeShellScript "entrypoint" ''
    set -euo pipefail

    export PATH="${pkgs.lib.makeBinPath [
      pkgs.minio
      pkgs.minio-client
      pkgs.caddy
      backend
      pkgs.coreutils
      pkgs.curl
    ]}"

    export HOME="/root"
    export LISTEN_ADDR="/run/reliquary/backend.sock"
    export MINIO_PORT="9000"

    mkdir -p /run/reliquary /data/minio /root

    # Start MinIO
    export MINIO_ROOT_USER="''${MINIO_ROOT_USER:-minioadmin}"
    export MINIO_ROOT_PASSWORD="''${MINIO_ROOT_PASSWORD:-minioadmin}"
    minio server /data/minio --address "127.0.0.1:9000" --console-address "127.0.0.1:9001" &
    MINIO_PID=$!

    # Wait for MinIO to be healthy
    echo "Waiting for MinIO..."
    for i in $(seq 1 30); do
      if curl -sf "http://127.0.0.1:9000/minio/health/live" -o /dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # Create bucket
    BUCKET="''${MINIO_BUCKET:-reliquary}"
    mc alias set local "http://127.0.0.1:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4
    mc mb --ignore-existing "local/$BUCKET"
    mc anonymous set download "local/$BUCKET"

    # Set MinIO env for backend
    export MINIO_ENDPOINT="127.0.0.1:9000"
    export MINIO_ACCESS_KEY="$MINIO_ROOT_USER"
    export MINIO_SECRET_KEY="$MINIO_ROOT_PASSWORD"

    # Start backend
    echo "Starting backend..."
    reliquary-be &
    BACKEND_PID=$!

    # Wait for backend socket
    for i in $(seq 1 30); do
      [ -S "$LISTEN_ADDR" ] && break
      sleep 0.5
    done

    # Start Caddy
    echo "Starting Caddy..."
    caddy run --config ${caddyfile} --adapter caddyfile &
    CADDY_PID=$!

    echo "Reliquary ready on :2080"

    # Wait for any process to exit
    wait -n $MINIO_PID $BACKEND_PID $CADDY_PID
    exit $?
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "reliquary";
  tag = "latest";

  contents = [
    backend
    pkgs.minio
    pkgs.minio-client
    pkgs.caddy
    pkgs.ffmpeg
    pkgs.cacert
    pkgs.coreutils
    pkgs.curl
    pkgs.bash
    pkgs.glibc.bin  # provides getent, needed by minio/mc
  ];

  extraCommands = ''
    mkdir -p srv/web run/reliquary data/minio tmp etc
    echo "root:x:0:0:root:/root:/bin/bash" > etc/passwd
    echo "root:x:0:" > etc/group
  '';

  config = {
    Entrypoint = [ "${entrypoint}" ];
    ExposedPorts = { "2080/tcp" = {}; };
    Env = [
      "MINIO_ROOT_USER=minioadmin"
      "MINIO_ROOT_PASSWORD=minioadmin"
      "MINIO_BUCKET=reliquary"
      "AUTH_USERNAME=admin"
      "AUTH_PASSWORD=admin"
      "JWT_SECRET=change-me-in-production"
      "THUMBNAIL_WORKERS=4"
      "ARCHIVE_AFTER_DAYS=90"
      "ARCHIVE_CHECK_HOURS=24"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Volumes = {
      "/data/minio" = {};
      "/srv/web" = {};
    };
  };
}
