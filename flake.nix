{
  description = "Flake for the reliquary project, includes development environment and infrastructure service definitions.";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
	let
	pkgs = import nixpkgs {
	inherit system;
	config.allowUnfree = true;
	};
	minioInfra = import ./infra/minio.nix { inherit pkgs; };
	yamlFormat = pkgs.formats.yaml {};
	processComposeConfig = yamlFormat.generate "process-compose.yaml" {
	  version = "0.5";
	  processes = minioInfra.processes;
	};
	infraShell = import ./shells/infra.nix { inherit pkgs processComposeConfig; };
	backendShell  = import ./shells/backend.nix { inherit pkgs infraShell; };
	frontendShell = import ./shells/frontend.nix { inherit pkgs infraShell; };
	in
	{
	devShells = rec {
	infra    = infraShell;
	backend  = backendShell;
	frontend = frontendShell;
	full     = pkgs.mkShell {
	  name = "reliquary-full-shell";
	  inputsFrom = [ backendShell frontendShell ];
	};
	default  = full;
	};
	}
  );
}
