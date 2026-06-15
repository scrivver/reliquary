{ pkgs }:

pkgs.buildGoModule {
  pname = "reliquary-be";
  version = "0.1.0";

  src = ../backend;

  vendorHash = "sha256-/OGWqjb9QTneTfGT4fz2LBIAGqMIEVuLQkbnx+OVrSI=";
  subPackages = [
    "."
    "cmd/reliquary-thumbnail-worker"
    "cmd/restore-archive"
  ];

  # Thumbnail worker runtime tools.
  nativeBuildInputs = [ pkgs.makeWrapper ];

  postInstall = ''
    wrapProgram $out/bin/reliquary-thumbnail-worker \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.ffmpeg pkgs.poppler-utils ]}
  '';

  meta = {
    description = "Reliquary backend API server";
    mainProgram = "reliquary-be";
  };
}
