# AGENT.md

## Roadmap & Progress

See **[PLAN.md](./PLAN.md)** for the full roadmap, task tracker, and session log.
That file is the source of truth for what's done, what's in progress, and what's next.

## What is this repo?

Containix is a **mini NixOS for containers**. It uses the NixOS module system
(`lib.evalModules`) so you can declaratively configure container images the same
way you configure a NixOS machine -- `services.nginx.enable = true` and it just
works. Under the hood it builds OCI images with
[nix2container](https://github.com/nlewo/nix2container) and uses
[s6-overlay](https://github.com/just-containers/s6-overlay) as the init system /
process supervisor.

## Repo layout

```
flake.nix                       # Flake entry point. Exports lib.mkContainer and lib.mkS6RcImage.
flake.lock                      # Pinned flake inputs.
mk-s6rc-image.nix               # Low-level builder: s6-overlay rootfs + nix2container image.
npins/
  sources.json                  # Pinned s6-overlay tarballs (managed by npins).
  default.nix                   # npins boilerplate (not used directly; we read sources.json).
modules/
  default.nix                   # Base module: core options (image.*, environment, packages, etc.)
  services/
    nginx.nix                   # services.nginx – NixOS-style virtualHosts/locations/upstreams.
    caddy.nix                   # services.caddy – Caddy with Caddyfile generation from virtualHosts.
    cron.nix                    # services.cron – Scheduled tasks via supercronic.
    grafana-alloy.nix           # services.grafana-alloy – metrics agent (prometheus scrape/remote-write).
    tailscale-ssh.nix           # services.tailscale-ssh – Tailscale VPN + Dropbear SSH access.
examples/
  nginx-static/                 # Minimal: nginx serving a static site.
  reverse-proxy/                # nginx reverse proxy + custom s6 app service.
  monitored-app/                # Full-stack: nginx + postgres + redis + alloy + cron + tailscale.
AGENT.md                        # This file.
README.md                       # Brief project description.
```

## Architecture

### Two layers

1. **`mk-s6rc-image.nix`** (low-level) -- A function that takes explicit args
   (`name`, `services`, `extraPaths`, etc.) and produces an OCI image derivation.
   It reads s6-overlay URLs and hashes from npins `sources.json`, handles tarball
   extraction, s6-rc service tree generation, `/usr/local/bin` symlinking, and the
   nix2container `buildImage` call. You can use this directly if you don't want
   the module system.

2. **Module system** (high-level) -- `flake.nix` defines `mkContainer` which
   calls `lib.evalModules` with the base module + all service modules, then maps
   the evaluated config to an `mkS6RcImage` call. This is the NixOS-like
   interface.

### How mkContainer works

```
User config  -->  evalModules  -->  evaluated config  -->  mkS6RcImage  -->  OCI image
                  (base module                             (mk-s6rc-image.nix
                   + service modules)                       + npins/sources.json)
```

### Module system conventions

- **Base module** (`modules/default.nix`): Defines the core option tree that maps
  1:1 to `mkS6RcImage` arguments:
  - `image.name`, `image.tag`, `image.user`
  - `image.labels` (OCI labels, e.g. `org.opencontainers.image.source`)
  - `image.exposedPorts` (list of port ints -> OCI EXPOSE)
  - `image.volumes` (list of path strings -> OCI volume mount points)
  - `image.healthcheck.{enable, command, interval, timeout, retries, startPeriod}`
  - `environment` (attrset of env vars)
  - `packages` (list of packages -> `/usr/local/bin`)
  - `copyToRoot` (extra rootfs store paths)
  - `files` (list of `{ source, target }`)
  - `secrets` (runtime secrets: `secrets.<name>.{file, envVar}`, defaults to
    `/run/secrets/<name>`, optional contenv integration)
  - `initScripts` (named oneshot scripts that run before all services)
  - `s6Services` (attrset of s6-rc service specs -- internal, populated by
    service modules)

- **Service modules** (`modules/services/*.nix`): Each file defines a service
  under `services.<name>`. Pattern:
  - Define `options.services.<name>` with `enable = lib.mkEnableOption "..."` plus
    service-specific options.
  - In `config = lib.mkIf cfg.enable { ... }`, populate `packages`, `files`,
    and `s6Services.<name>` as needed.

- **Auto-discovery**: `flake.nix` imports every file in `modules/services/`
  automatically. Drop a new `.nix` file there and it's available.

### How to add a new service module

Create `modules/services/<name>.nix`:

```nix
{ lib, pkgs, config, ... }:
let cfg = config.services.<name>;
in {
  options.services.<name> = {
    enable = lib.mkEnableOption "<name> service";
    # ... service-specific options ...
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];  # if it needs binaries in PATH

    files = [
      { source = someConfigFile; target = "etc/<name>/<name>.conf"; }
    ];

    s6Services.<name> = {
      kind = "longrun";  # or "oneshot"
      run = ''
        exec <name> --config /etc/<name>/<name>.conf
      '';
      # after = [ "some-other-service" ];  # optional dependencies
    };
  };
}
```

### s6-rc service types

- **longrun**: A daemon. Needs `run` script. s6 supervises it and restarts on crash.
- **oneshot**: An init task. Needs `up` script, optional `down` script. Runs once
  at container start.
- **after**: List of service names this service depends on. s6-rc starts them in
  dependency order.

## Dependency management

### Flake inputs (flake.lock)

| Input            | Purpose                                      |
|------------------|----------------------------------------------|
| `nixpkgs`        | Package set (tracks nixpkgs-unstable)        |
| `flake-utils`    | `eachDefaultSystem` helper                   |
| `nix2container`  | OCI image builder (follows nixpkgs)          |

### npins (npins/sources.json)

s6-overlay release tarballs are pinned with [npins](https://github.com/andir/npins).
The pins are frozen (won't auto-update with `npins update`).

Current pins:
- `s6-overlay-noarch` -- architecture-independent s6-overlay files
- `s6-overlay-x86_64` -- x86_64 binaries
- `s6-overlay-aarch64` -- aarch64 binaries

To update s6-overlay to a new version, remove and re-add the pins:
```sh
npins remove s6-overlay-noarch
npins remove s6-overlay-x86_64
npins remove s6-overlay-aarch64
npins add tarball --name s6-overlay-noarch --frozen "https://github.com/just-containers/s6-overlay/releases/download/v<VERSION>/s6-overlay-noarch.tar.xz"
npins add tarball --name s6-overlay-x86_64 --frozen "https://github.com/just-containers/s6-overlay/releases/download/v<VERSION>/s6-overlay-x86_64.tar.xz"
npins add tarball --name s6-overlay-aarch64 --frozen "https://github.com/just-containers/s6-overlay/releases/download/v<VERSION>/s6-overlay-aarch64.tar.xz"
```

Note: `flake.nix` reads `npins/sources.json` directly (not `npins/default.nix`)
because we need the raw `.tar.xz` files via `pkgs.fetchurl`, not the unpacked
store paths that npins' `fetchTarball`/`fetchzip` would produce.

## Flake outputs

- `lib.<system>.mkContainer` -- Module-based container builder (the main API).
- `lib.<system>.mkS6RcImage` -- Low-level image builder (escape hatch).

## Available services

| Service                  | Key options                                                    |
|--------------------------|----------------------------------------------------------------|
| `services.nginx`         | `virtualHosts.<name>.locations.<path>.proxyPass`, `upstreams`  |
| `services.caddy`         | `virtualHosts.<name>.extraConfig`, `globalConfig`              |
| `services.cron`          | `jobs.<name>.{schedule, command}`                              |
| `services.grafana-alloy` | `configFile` or `configText`, `postgres.customQueries`         |
| `services.tailscale-ssh` | `loginServer`, `advertiseExitNode`, `sshPort`, `extraPackages` |

The nginx module generates `nginx.conf` from structured `virtualHosts`, `locations`,
and `upstreams` options -- same pattern as the NixOS nginx module. The caddy module
generates a `Caddyfile` from `virtualHosts`. Both support raw config escape hatches.

## Consumer usage

```nix
{
  inputs.containix.url = "github:cramt/containix";

  outputs = { containix, ... }: {
    packages.x86_64-linux.my-image =
      containix.lib.x86_64-linux.mkContainer {
        image.name = "my-app";

        services.nginx = {
          enable = true;
          upstreams.app.servers."127.0.0.1:3000" = {};
          virtualHosts.localhost.locations."/".proxyPass = "http://app";
        };
      };
  };
}
```

## Examples

See `examples/` for complete, self-contained flakes:

- **`nginx-static/`** -- Minimal nginx serving a static HTML site.
- **`reverse-proxy/`** -- nginx reverse proxy with upstreams + a custom s6 app service.
- **`monitored-app/`** -- Full-stack: nginx + alloy + cron + tailscale.

## Supported platforms

`x86_64-linux` and `aarch64-linux` for image builds (s6-overlay constraint).
The flake evaluates for all default systems.

## Development

- No formal test suite yet. Validate with `nix flake show` and `nix eval`.
- Quick smoke test:
  ```sh
  nix eval --impure --expr '
    let
      flake = builtins.getFlake (toString ./.);
      mkContainer = flake.lib.x86_64-linux.mkContainer;
    in (mkContainer {
      image.name = "test";
      services.nginx.enable = true;
    }).name
  '
  ```
- The `files` option `source` field accepts both paths and derivations
  (e.g. `pkgs.writeText` output).
