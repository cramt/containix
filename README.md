# Containix

**A mini NixOS for containers** — Build OCI container images using the NixOS module system.

Containix lets you configure container images declaratively using familiar NixOS patterns like `services.nginx.enable = true`. Under the hood, it uses [nix2container](https://github.com/nlewo/nix2container) for efficient layered images and [s6-overlay](https://github.com/just-containers/s6-overlay) for process supervision.

## Features

- **NixOS module system** — Configure containers with the same declarative patterns you use for NixOS
- **Built-in services** — nginx, Caddy, cron, Grafana Alloy, Tailscale SSH, and more
- **Production-ready** — OCI metadata (labels, healthchecks, exposed ports), runtime secrets, init scripts
- **Efficient images** — Leverages nix2container for optimal layer caching
- **Process supervision** — s6-overlay manages service lifecycle and dependencies

## Quick Start

### Using the flake template

```bash
nix flake init -t github:cramt/containix
```

### Manual setup

Create a `flake.nix`:

```nix
{
  inputs.containix.url = "github:cramt/containix";

  outputs = { containix, ... }: {
    packages.x86_64-linux.my-image =
      containix.lib.x86_64-linux.mkContainer {
        image.name = "my-app";
        image.tag = "latest";

        services.nginx = {
          enable = true;
          virtualHosts.localhost.locations."/".root = "/var/www";
        };

        files = [
          { source = ./static; target = "var/www"; }
        ];
      };
  };
}
```

Build and run:

```bash
nix build .#my-image
docker load < result
docker run -p 80:80 my-app
```

## Examples

See the [`examples/`](./examples) directory for complete working examples:

- **[nginx-static](./examples/nginx-static)** — Minimal nginx serving static files
- **[reverse-proxy](./examples/reverse-proxy)** — nginx reverse proxy with custom application service
- **[monitored-app](./examples/monitored-app)** — Full-stack setup with nginx, Grafana Alloy, cron, and Tailscale

## API Reference

### Core Options

#### `image.*`

- `image.name` (string) — Container image name
- `image.tag` (string, default: `"latest"`) — Image tag
- `image.user` (string, default: `"root"`) — Default user for container processes
- `image.labels` (attrset) — OCI labels (e.g., `org.opencontainers.image.source`)
- `image.exposedPorts` (list of ints) — Ports to expose in OCI metadata
- `image.volumes` (list of paths) — Volume mount points to declare

#### `image.healthcheck.*`

Configure OCI HEALTHCHECK metadata:

```nix
image.healthcheck = {
  enable = true;
  command = ["curl" "-f" "http://localhost/health"];
  interval = 30;      # seconds
  timeout = 3;
  retries = 3;
  startPeriod = 5;
};
```

#### `environment`

Attrset of environment variables:

```nix
environment = {
  PORT = "8080";
  LOG_LEVEL = "info";
};
```

#### `packages`

List of packages to make available in `/usr/local/bin`:

```nix
packages = [ pkgs.curl pkgs.jq ];
```

#### `files`

Copy files into the image:

```nix
files = [
  { source = ./config.yml; target = "etc/app/config.yml"; }
  { source = pkgs.writeText "motd" "Welcome!"; target = "etc/motd"; }
];
```

#### `secrets.*`

Runtime secrets from mounted files (Docker/Kubernetes compatible):

```nix
secrets.db-password = {
  file = "/run/secrets/db-password";  # default: /run/secrets/<name>
  envVar = "DB_PASSWORD";              # optional: expose as env var via contenv
};
```

Secrets are read at container startup. If `envVar` is set, the secret value is exposed as an environment variable to all services.

#### `initScripts.*`

Oneshot scripts that run before services start:

```nix
initScripts.setup-db = ''
  mkdir -p /var/lib/db
  chown app:app /var/lib/db
'';
```

#### `s6Services.*`

Low-level s6-rc service definitions (usually populated by service modules):

```nix
s6Services.my-app = {
  kind = "longrun";
  run = ''
    exec my-app --port 3000
  '';
  after = [ "nginx" ];  # optional dependencies
};
```

Service kinds:
- `longrun` — Supervised daemon (requires `run` script)
- `oneshot` — Init task (requires `up` script, optional `down`)

### Available Services

#### `services.nginx`

NixOS-style nginx configuration with structured virtualHosts:

```nix
services.nginx = {
  enable = true;
  
  upstreams.backend.servers = {
    "127.0.0.1:3000" = {};
    "127.0.0.1:3001" = {};
  };
  
  virtualHosts."example.com" = {
    locations."/" = {
      proxyPass = "http://backend";
      extraConfig = ''
        proxy_set_header X-Real-IP $remote_addr;
      '';
    };
    locations."/static/" = {
      root = "/var/www";
    };
  };
};
```

#### `services.caddy`

Caddy web server with Caddyfile generation:

```nix
services.caddy = {
  enable = true;
  
  virtualHosts."example.com" = {
    extraConfig = ''
      reverse_proxy localhost:3000
    '';
  };
  
  globalConfig = ''
    auto_https off
  '';
};
```

#### `services.cron`

Scheduled tasks via supercronic:

```nix
services.cron = {
  enable = true;
  
  jobs.backup = {
    schedule = "0 2 * * *";  # 2 AM daily
    command = "/usr/local/bin/backup.sh";
  };
};
```

#### `services.grafana-alloy`

Metrics and logs collection agent:

```nix
services.grafana-alloy = {
  enable = true;
  configText = ''
    prometheus.scrape "default" {
      targets = [{"__address__" = "localhost:9090"}]
      forward_to = [prometheus.remote_write.default.receiver]
    }
    
    prometheus.remote_write "default" {
      endpoint {
        url = "https://prometheus.example.com/api/v1/write"
      }
    }
  '';
};
```

#### `services.tailscale-ssh`

Tailscale VPN with SSH access via Dropbear:

```nix
services.tailscale-ssh = {
  enable = true;
  authKeyFile = "/run/secrets/tailscale-key";
  sshPort = 22;
  extraPackages = [ pkgs.htop pkgs.vim ];
};
```

## Comparison to Alternatives

### vs. Nixery

[Nixery](https://nixery.dev) dynamically builds images on-demand from package names in the image URL. Containix is for building custom application images with declarative configuration and service orchestration.

### vs. dockerTools.buildImage

Nix's built-in `dockerTools.buildImage` creates basic images but doesn't provide:
- Process supervision (s6-overlay)
- Service dependency management
- NixOS-style module system for configuration
- Built-in service modules (nginx, caddy, etc.)

### vs. NixOS containers

NixOS `containers.*` are system containers (systemd-nspawn) that run on NixOS hosts. Containix builds OCI images that run anywhere (Docker, Kubernetes, Podman).

### vs. Dockerfile

Containix provides:
- **Reproducibility** — Nix ensures bit-for-bit identical rebuilds
- **Efficient caching** — nix2container creates optimal layers based on dependency graph
- **Declarative config** — No imperative RUN commands, just pure configuration
- **Type safety** — NixOS module system validates configuration at eval time

## Architecture

Containix has two layers:

1. **Low-level builder** (`mk-s6rc-image.nix`) — Takes explicit arguments and produces an OCI image with s6-overlay
2. **Module system** (`mkContainer`) — Evaluates NixOS modules and calls the low-level builder

```
User config → evalModules → evaluated config → mkS6RcImage → OCI image
              (modules/)                        (mk-s6rc-image.nix)
```

Service modules in `modules/services/*.nix` are auto-discovered and define options under `services.*`.

## Adding Custom Services

Create `modules/services/myservice.nix`:

```nix
{ lib, pkgs, config, ... }:
let cfg = config.services.myservice;
in {
  options.services.myservice = {
    enable = lib.mkEnableOption "myservice";
    port = lib.mkOption {
      type = lib.types.int;
      default = 8080;
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ pkgs.myservice ];
    
    s6Services.myservice = {
      kind = "longrun";
      run = ''
        exec myservice --port ${toString cfg.port}
      '';
    };
  };
}
```

## Supported Platforms

- `x86_64-linux`
- `aarch64-linux`

(s6-overlay constraint)

## Development

See [PLAN.md](./PLAN.md) for the roadmap and [AGENT.md](./AGENT.md) for architecture details.

Run checks:

```bash
nix flake check
```

Build all examples:

```bash
nix build .#checks.x86_64-linux.examples-nginx-static
nix build .#checks.x86_64-linux.examples-reverse-proxy
nix build .#checks.x86_64-linux.examples-monitored-app
```

## License

MIT
