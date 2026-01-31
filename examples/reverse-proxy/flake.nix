# Reverse proxy example: nginx in front of an upstream app server.
#
# Build:  nix build .#container
# Load:   docker load < result
# Run:    docker run -p 8080:8080 reverse-proxy
{
  inputs = {
    containix.url = "github:cramt/containix";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { containix, nixpkgs, ... }: let
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    mkContainer = containix.lib.x86_64-linux.mkContainer;

    # A tiny example app: python HTTP server.
    app = pkgs.writeShellApplication {
      name = "example-app";
      runtimeInputs = [ pkgs.python3 ];
      text = ''
        python3 -m http.server 3000
      '';
    };
  in {
    packages.x86_64-linux.container = mkContainer {
      image.name = "reverse-proxy";
      image.tag = "latest";

      packages = [ app ];

      services.nginx = {
        enable = true;
        upstreams.app.servers."127.0.0.1:3000" = {};
        virtualHosts.localhost = {
          locations."/" = {
            proxyPass = "http://app";
          };
          locations."/health" = {
            return = "200 ok";
            extraConfig = ''
              add_header Content-Type text/plain;
            '';
          };
        };
      };

      # Run the app as a separate s6 longrun service.
      s6Services.app = {
        kind = "longrun";
        run = "exec example-app";
      };
    };
  };
}
