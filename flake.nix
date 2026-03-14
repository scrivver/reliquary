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
	in
	{
	devShells = rec {

	dev = pkgs.mkShell {
	name = "reliquary-dev-shell";
	buildInputs = [
	pkgs.minio
	pkgs.process-compose
	pkgs.python3
	pkgs.curl
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

	# Export port file paths so other services can read the dynamic ports
	export MINIO_PORT_FILE="$DATA_DIR/minio/port"
	export MINIO_CONSOLE_PORT_FILE="$DATA_DIR/minio/console_port"

	'';

	};

	default = dev;
	};
	}
  );
}
