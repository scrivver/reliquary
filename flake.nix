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
	rabbitmqInfra = import ./infra/rabbitmq.nix { inherit pkgs; };
	caddyInfra = import ./infra/caddy.nix { inherit pkgs; };
	yamlFormat = pkgs.formats.yaml {};
	processComposeConfig = yamlFormat.generate "process-compose.yaml" {
	  version = "0.5";
	  processes = rabbitmqInfra.processes // minioInfra.processes // caddyInfra.processes;
	};
	infraShell = import ./shells/infra.nix { inherit pkgs processComposeConfig; };
	backendShell  = import ./shells/backend.nix { inherit pkgs infraShell; };
	frontendShell = import ./shells/frontend.nix { inherit pkgs infraShell; };
	backendPkg = import ./nix/backend.nix { inherit pkgs; };
	frontendWebPkg = import ./nix/frontend-web.nix { inherit pkgs; };
	containerImg = import ./nix/container.nix { inherit pkgs; };
	apiImg = import ./nix/api-container.nix { inherit pkgs; };
	ingressImg = import ./nix/ingress-container.nix { inherit pkgs; };
	webImg = import ./nix/web-container.nix { inherit pkgs; };
	thumbnailWorkerImg = import ./nix/thumbnail-worker-container.nix { inherit pkgs; };
	in
	{
	packages = {
	backend = backendPkg;
	frontend-web = frontendWebPkg;
	container = containerImg;
	api-container = apiImg;
	ingress-container = ingressImg;
	web-container = webImg;
	thumbnail-worker-container = thumbnailWorkerImg;
	default = backendPkg;
	};
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
