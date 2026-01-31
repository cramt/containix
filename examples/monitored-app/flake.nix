# Full-stack example: nginx + postgres + redis + alloy metrics + cron + tailscale SSH.
#
# Demonstrates using most containix services together in a single container.
{
  inputs = {
    containix.url = "github:cramt/containix";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { containix, nixpkgs, ... }: let
    pkgs = import nixpkgs { system = "x86_64-linux"; };
    mkContainer = containix.lib.x86_64-linux.mkContainer;
  in {
    packages.x86_64-linux.container = mkContainer {
      image.name = "monitored-app";
      image.tag = "latest";

      environment = {
        APP_ENV = "production";
      };

      # --- nginx: reverse proxy to the app ---
      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedProxySettings = true;
        upstreams.app.servers."127.0.0.1:3000" = {};
        virtualHosts.localhost = {
          locations."/" = {
            proxyPass = "http://app";
            proxyWebsockets = true;
          };
          locations."/static" = {
            root = "/srv";
            tryFiles = "$uri =404";
          };
        };
      };

      # --- postgresql: application database ---
      services.postgresql = {
        enable = true;
        ensureDatabases = [ "myapp" ];
        ensureUsers = [ "myapp" ];
        maxConnections = 50;
        sharedBuffers = "256MB";
      };

      # --- redis: caching / sessions ---
      services.redis = {
        enable = true;
        maxMemory = "128mb";
        maxMemoryPolicy = "allkeys-lru";
      };

      # --- grafana-alloy: metrics collection ---
      services.grafana-alloy = {
        enable = true;
        configText = ''
          prometheus.scrape "app" {
            scrape_interval = "30s"
            scrape_timeout  = "4s"
            targets = [{
              __address__     = "localhost:3000",
              __metrics_path__ = "/metrics",
              __scheme__      = "http",
            }]
            forward_to = [prometheus.remote_write.default.receiver]
          }

          prometheus.remote_write "default" {
            endpoint {
              url = sys.env("PROMETHEUS_REMOTE_WRITE_URL")
            }
          }
        '';
      };

      # --- cron: periodic tasks ---
      services.cron = {
        enable = true;
        jobs = {
          healthcheck = {
            schedule = "*/5 * * * *";
            command = "curl -sf http://localhost:8080/health > /dev/null";
          };
          cleanup = {
            schedule = "0 3 * * *";
            command = "curl -sf -XPOST http://localhost:3000/admin/cleanup > /dev/null";
          };
        };
      };

      # --- tailscale-ssh: remote access ---
      services.tailscale-ssh = {
        enable = true;
        loginServer = "https://hs.example.com";
        advertiseExitNode = false;
        extraPackages = [ pkgs.busybox pkgs.curl pkgs.htop ];
      };
    };
  };
}
