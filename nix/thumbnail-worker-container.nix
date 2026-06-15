{ pkgs }:

let
  backend = import ./backend.nix { inherit pkgs; };
in
pkgs.dockerTools.buildLayeredImage {
  name = "reliquary-thumbnail-worker";
  tag = "latest";

  contents = [
    backend
    pkgs.ffmpeg
    pkgs.poppler-utils
    pkgs.cacert
  ];

  config = {
    Entrypoint = [ "${backend}/bin/reliquary-thumbnail-worker" ];
    Env = [
      "MINIO_PORT=9000"
      "RABBITMQ_URL=amqp://guest:guest@rabbitmq:5672"
      "THUMBNAIL_QUEUE=reliquary.thumbnail"
      "THUMBNAIL_DEAD_QUEUE=reliquary.thumbnail.dead"
      "THUMBNAIL_PREFETCH=1"
      "THUMBNAIL_CONCURRENCY=4"
      "THUMBNAIL_MAX_ATTEMPTS=5"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
  };
}
