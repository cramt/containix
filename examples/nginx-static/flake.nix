# Minimal example: nginx serving a static site.
#
# Build:  nix build .#container
# Load:   docker load < result
# Run:    docker run -p 8080:8080 nginx-static
{
  inputs.containix.url = "github:cramt/containix";

  outputs = { containix, ... }: let
    mkContainer = containix.lib.x86_64-linux.mkContainer;
  in {
    packages.x86_64-linux.container = mkContainer {
      image.name = "nginx-static";
      image.tag = "latest";

      services.nginx = {
        enable = true;
        virtualHosts.localhost = {
          locations."/" = {
            root = "/srv/www";
            index = "index.html";
            tryFiles = "$uri $uri/ =404";
          };
        };
      };

      files = [
        { source = ./site; target = "srv/www"; }
      ];
    };
  };
}
