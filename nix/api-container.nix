{ pkgs }:

let
  backend = import ./backend.nix { inherit pkgs; };
  healthcheck = pkgs.writeShellScriptBin "reliquary-api-healthcheck" ''
    exec ${pkgs.curl}/bin/curl --fail --silent --show-error \
      http://127.0.0.1:8080/api/health >/dev/null
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = "reliquary-api";
  tag = "latest";

  contents = [
    backend
    healthcheck
    pkgs.cacert
    pkgs.curl
  ];

  config = {
    Entrypoint = [ "${backend}/bin/reliquary-be" ];
    ExposedPorts = { "8080/tcp" = {}; };
    Env = [
      "PORT=8080"
      "MINIO_PORT=9000"
      "MINIO_ENDPOINT=minio:9000"
      "RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
  };
}
