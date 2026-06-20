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
	devAppProcesses = {
	  backend = {
	    command = pkgs.writeShellScript "reliquary-dev-backend" ''
	      set -euo pipefail

	      until [ -f "$MINIO_PORT_FILE" ] && [ -f "$RABBITMQ_AMQP_PORT_FILE" ]; do
	        echo "Waiting for infrastructure ports..."
	        sleep 1
	      done

	      source "$PROJECT_ROOT/bin/load-infra-env"
	      export LISTEN_ADDR="$DATA_DIR/backend.sock"

	      cd "$PROJECT_ROOT/backend"
	      exec ${pkgs.air}/bin/air
	    '';
	    depends_on = {
	      minio.condition = "process_healthy";
	      rabbitmq.condition = "process_healthy";
	    };
	  };

	  thumbnail-worker = {
	    command = pkgs.writeShellScript "reliquary-dev-thumbnail-worker" ''
	      set -euo pipefail

	      until [ -f "$MINIO_PORT_FILE" ] && [ -f "$RABBITMQ_AMQP_PORT_FILE" ]; do
	        echo "Waiting for infrastructure ports..."
	        sleep 1
	      done

	      source "$PROJECT_ROOT/bin/load-infra-env"

	      cd "$PROJECT_ROOT/backend"
	      exec ${pkgs.go}/bin/go run ./cmd/reliquary-thumbnail-worker
	    '';
	    depends_on = {
	      minio.condition = "process_healthy";
	      rabbitmq.condition = "process_healthy";
	    };
	  };

	  frontend = {
	    command = pkgs.writeShellScript "reliquary-dev-frontend" ''
	      set -euo pipefail

	      cd "$PROJECT_ROOT/frontend"
	      exec ${pkgs.flutter}/bin/flutter run \
	        -d web-server \
	        --web-port=3000 \
	        --dart-define=RELIQUARY_DEFAULT_API_BASE_URL=http://localhost:2080
	    '';
	    depends_on = {
	      caddy.condition = "process_healthy";
	      backend.condition = "process_started";
	    };
	  };
	};
	yamlFormat = pkgs.formats.yaml {};
	processComposeConfig = yamlFormat.generate "process-compose.yaml" {
	  version = "0.5";
	  processes = rabbitmqInfra.processes // minioInfra.processes // caddyInfra.processes;
	};
	devProcessComposeConfig = yamlFormat.generate "dev-process-compose.yaml" {
	  version = "0.5";
	  processes = rabbitmqInfra.processes // minioInfra.processes // caddyInfra.processes // devAppProcesses;
	};
	infraShell = import ./shells/infra.nix { inherit pkgs processComposeConfig devProcessComposeConfig; };
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
