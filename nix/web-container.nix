{ pkgs }:

let
  frontendWeb = import ./frontend-web.nix { inherit pkgs; };
  healthcheck = pkgs.writeShellScriptBin "reliquary-web-healthcheck" ''
    ${pkgs.curl}/bin/curl --fail --silent --show-error \
      http://127.0.0.1:2080/api/health >/dev/null
    exec ${pkgs.curl}/bin/curl --fail --silent --show-error \
      http://127.0.0.1:2080/index.html >/dev/null
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = "reliquary-web";
  tag = "latest";

  contents = [
    pkgs.caddy
    pkgs.cacert
    pkgs.curl
    healthcheck
  ];

  extraCommands = ''
    mkdir -p etc/caddy srv/web
    cp ${../docker/Caddyfile} etc/caddy/Caddyfile
    cp -R ${frontendWeb}/. srv/web/
  '';

  config = {
    Entrypoint = [
      "${pkgs.caddy}/bin/caddy"
      "run"
      "--config"
      "/etc/caddy/Caddyfile"
      "--adapter"
      "caddyfile"
    ];
    ExposedPorts = { "2080/tcp" = {}; };
    Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
  };
}
