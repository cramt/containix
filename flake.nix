{
  description = "containix – a mini NixOS for containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix2container = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nlewo/nix2container";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    nix2container,
    ...
  }:
    {
      templates.default = {
        path = ./templates/default;
        description = "A basic containix container with nginx";
      };
    } //
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      nix2containerPkgs = nix2container.packages.${system};

      # npins sources – read the raw JSON so we get url+hash for fetchurl,
      # rather than using npins' default.nix which unpacks tarballs.
      sources = (builtins.fromJSON (builtins.readFile ./npins/sources.json)).pins;

      mkS6RcImage = import ./mk-s6rc-image.nix { inherit pkgs nix2containerPkgs sources; };

      # Auto-discover service modules from modules/services/
      serviceModuleDir = ./modules/services;
      serviceModules =
        lib.optionalAttrs (builtins.pathExists serviceModuleDir)
          (builtins.readDir serviceModuleDir);
      serviceModuleList =
        lib.mapAttrsToList
          (name: _: import (serviceModuleDir + "/${name}"))
          serviceModules;

      # All modules: base + all service modules
      allModules = [ ./modules/default.nix ] ++ serviceModuleList;

      # mkContainer :: config -> image derivation
      # Evaluates the module system and calls mkS6RcImage with the result.
      mkContainer = config: let
        rawConfig = (lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = allModules ++ [
            ({ ... }: config)
          ];
        }).config;

        # Check assertions (NixOS-style).
        failedAssertions = builtins.filter (a: !a.assertion) rawConfig.assertions;
        assertionMessages = builtins.map (a: a.message) failedAssertions;

        # Abort if any assertions fail; print warnings otherwise.
        evaluated =
          if failedAssertions != [] then
            throw "containix: Failed assertions:\n${lib.concatStringsSep "\n" (map (m: "- ${m}") assertionMessages)}"
          else if rawConfig.warnings != [] then
            builtins.trace "containix warnings:\n${lib.concatStringsSep "\n" (map (m: "- ${m}") rawConfig.warnings)}" rawConfig
          else rawConfig;
      in
        let
          # Secrets that need contenv integration (file -> env var).
          secretsWithEnv = lib.filterAttrs (_: s: s.envVar != null) evaluated.secrets;
          hasSecrets = secretsWithEnv != {};

          # Generate a oneshot that reads secret files into s6 contenv dir
          # so they become environment variables for all services.
          secretsInitScript = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: secret: ''
            if [ -f "${secret.file}" ]; then
              cat "${secret.file}" > /run/s6/container_environment/${secret.envVar}
            else
              echo "containix: warning: secret file '${secret.file}' not found" >&2
            fi
          '') secretsWithEnv);

          secretsService = lib.optionalAttrs hasSecrets {
            "init-secrets" = {
              kind = "oneshot";
              after = [];
              up = ''
                mkdir -p /run/s6/container_environment
                ${secretsInitScript}
              '';
            };
          };

          # Merge user-defined s6Services with auto-generated initScript services.
          # Each initScript becomes a oneshot service named "init-<name>" that all
          # other services implicitly depend on.
          initServiceNames =
            (lib.mapAttrsToList (name: _: "init-${name}") evaluated.initScripts)
            ++ (lib.optional hasSecrets "init-secrets");
          initServices = lib.mapAttrs' (name: script:
            lib.nameValuePair "init-${name}" {
              kind = "oneshot";
              after = if hasSecrets then [ "init-secrets" ] else [];
              up = script;
            }
          ) evaluated.initScripts;

          # Add initScript dependencies to all user-defined services.
          userServices = lib.mapAttrs (_: svc:
            { inherit (svc) kind;
              after = svc.after ++ initServiceNames;
            }
            // lib.optionalAttrs (svc.run != null) { inherit (svc) run; }
            // lib.optionalAttrs (svc.up != null) { inherit (svc) up; }
            // lib.optionalAttrs (svc.down != null) { inherit (svc) down; }
          ) evaluated.s6Services;
        in
        mkS6RcImage {
          name = evaluated.image.name;
          tag = evaluated.image.tag;
          user = evaluated.image.user;
          env = evaluated.environment;
          extraPaths = evaluated.packages;
          copyToRoot = evaluated.copyToRoot;
          extraFiles = evaluated.files;
          labels = evaluated.image.labels;
          exposedPorts = evaluated.image.exposedPorts;
          volumes = evaluated.image.volumes;
          healthcheck =
            if evaluated.image.healthcheck.enable then {
              command = evaluated.image.healthcheck.command;
              interval = evaluated.image.healthcheck.interval;
              timeout = evaluated.image.healthcheck.timeout;
              retries = evaluated.image.healthcheck.retries;
              startPeriod = evaluated.image.healthcheck.startPeriod;
            } else null;
          services = secretsService // initServices // userServices;
        };
    in {
      lib = {
        inherit mkS6RcImage mkContainer;
      };

      # Development shell for working on containix itself.
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.npins
          pkgs.nix-output-monitor
        ];
      };

      # Evaluation checks for `nix flake check`.
      # These verify that the module system evaluates correctly for various
      # configurations. They don't build images (that would require a builder),
      # but they catch type errors, assertion failures, and option misuse.
      checks = let
        # Helper: evaluate a config and return a trivial derivation if it succeeds.
        checkConfig = name: config:
          let img = mkContainer config;
          in pkgs.runCommand "containix-check-${name}" {} ''
            echo "containix check '${name}' evaluated successfully: ${img.name}"
            touch $out
          '';
      in {
        # Minimal: just an image name, no services.
        eval-minimal = checkConfig "minimal" {
          image.name = "check-minimal";
        };

        # nginx basic.
        eval-nginx = checkConfig "nginx" {
          image.name = "check-nginx";
          services.nginx = {
            enable = true;
            virtualHosts.localhost.locations."/".return = "200 ok";
          };
        };

        # caddy basic.
        eval-caddy = checkConfig "caddy" {
          image.name = "check-caddy";
          services.caddy = {
            enable = true;
            virtualHosts.localhost = {};
          };
        };

        # cron.
        eval-cron = checkConfig "cron" {
          image.name = "check-cron";
          services.cron = {
            enable = true;
            jobs.test = { schedule = "* * * * *"; command = "echo ok"; };
          };
        };

        # All new features: labels, ports, volumes, healthcheck, initScripts, secrets.
        eval-full = checkConfig "full" {
          image.name = "check-full";
          image.tag = "test";
          image.labels = { "org.opencontainers.image.source" = "test"; };
          image.exposedPorts = [ 8080 ];
          image.volumes = [ "/data" ];
          image.healthcheck = {
            enable = true;
            command = "true";
            interval = "30s";
            timeout = "5s";
            retries = 3;
            startPeriod = "10s";
          };
          environment.FOO = "bar";
          initScripts.setup = "mkdir -p /data";
          secrets.my-secret.envVar = "MY_SECRET";
          services.nginx = {
            enable = true;
            virtualHosts.localhost.locations."/".return = "200 ok";
          };
        };

        # Custom s6 service (no module, raw s6Services).
        eval-custom-service = checkConfig "custom-service" {
          image.name = "check-custom";
          s6Services.myapp = {
            kind = "longrun";
            run = "exec echo hello";
          };
        };
      };
    });
}
