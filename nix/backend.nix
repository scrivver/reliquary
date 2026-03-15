{ pkgs }:

pkgs.buildGoModule {
  pname = "reliquary-be";
  version = "0.1.0";

  src = ../backend;

  vendorHash = "sha256-6tKINcMT9d5G5jyMkZPoCAwnY4+sdNRFK1wsR030FQY=";

  # ffmpeg and poppler-utils needed at runtime for thumbnail generation
  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/reliquary-be \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ffmpeg pkgs.poppler-utils ]}
  '';

  meta = {
    description = "Reliquary backend API server";
    mainProgram = "reliquary-be";
  };
}
