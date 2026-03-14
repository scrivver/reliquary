{ pkgs, proxyPort ? "2080" }:
{
  processes = {
    caddy = {
      command = pkgs.writeShellScript "start-caddy" ''
        set -euo pipefail

        MINIO_PORT=$(cat "$DATA_DIR/minio/port")
        PROXY_PORT="${proxyPort}"
        BACKEND_SOCK="$DATA_DIR/backend.sock"

        CADDY_DIR="$DATA_DIR/caddy"
        mkdir -p "$CADDY_DIR"

        cat > "$CADDY_DIR/Caddyfile" <<CADDYEOF
        {
          admin off
        }

        :''${PROXY_PORT} {
          header Access-Control-Allow-Origin *
          header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
          header Access-Control-Allow-Headers "Accept, Authorization, Content-Type"

          @options method OPTIONS
          handle @options {
            respond 204
          }

          handle /api/* {
            reverse_proxy unix/$BACKEND_SOCK
          }

          handle /storage/* {
            uri strip_prefix /storage
            reverse_proxy 127.0.0.1:''${MINIO_PORT} {
              header_up Host 127.0.0.1:''${MINIO_PORT}
              header_down -Access-Control-Allow-Origin
              header_down -Access-Control-Allow-Methods
              header_down -Access-Control-Allow-Headers
            }
          }
        }
        CADDYEOF

        echo "$PROXY_PORT" > "$CADDY_DIR/port"
        echo "Caddy proxy starting on :$PROXY_PORT"
        echo "  /api/*     -> unix/$BACKEND_SOCK"
        echo "  /storage/* -> 127.0.0.1:$MINIO_PORT"

        exec ${pkgs.caddy}/bin/caddy run --config "$CADDY_DIR/Caddyfile"
      '';
      depends_on = {
        minio.condition = "process_healthy";
      };
      readiness_probe = {
        exec.command = pkgs.writeShellScript "caddy-ready" ''
          PROXY_PORT=$(cat "$DATA_DIR/caddy/port" 2>/dev/null) || exit 1
          curl -sf "http://127.0.0.1:$PROXY_PORT" -o /dev/null 2>&1 || true
        '';
        initial_delay_seconds = 2;
        period_seconds = 2;
      };
    };
  };

  inherit proxyPort;
}
