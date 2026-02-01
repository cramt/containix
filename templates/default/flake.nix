# containix container image
#
# Build:  nix build .#container
# Load:   docker load < result
# Run:    docker run -p 8080:8080 my-container
{
  inputs = {
    containix.url = "github:cramt/containix";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { containix, nixpkgs, ... }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    mkContainer = containix.lib.${system}.mkContainer;
  in {
    packages.${system}.container = mkContainer {
      image.name = "my-container";
      image.tag = "latest";

      # OCI metadata
      # image.labels."org.opencontainers.image.source" = "https://github.com/you/your-repo";
      # image.exposedPorts = [ 8080 ];
      # image.volumes = [ "/data" ];

      # Healthcheck (uncomment and adjust)
      # image.healthcheck = {
      #   enable = true;
      #   command = "curl -sf http://localhost:8080/health";
      # };

      # Environment variables
      # environment = {
      #   APP_ENV = "production";
      # };

      # Runtime secrets (mounted by Docker/Kubernetes/Podman)
      # secrets.db-password.envVar = "DATABASE_PASSWORD";

      # Init scripts (run before services start)
      # initScripts.setup = "mkdir -p /data";

      # Extra packages available in the container
      # packages = [ pkgs.curl pkgs.jq ];

      # --- nginx reverse proxy ---
      services.nginx = {
        enable = true;
        virtualHosts.localhost = {
          locations."/" = {
            return = "200 'Hello from containix!'";
            extraConfig = "add_header Content-Type text/plain;";
          };
        };
      };

      # --- cron jobs ---
      # services.cron = {
      #   enable = true;
      #   jobs.healthcheck = {
      #     schedule = "*/5 * * * *";
      #     command = "echo ok";
      #   };
      # };
    };
  };
}
