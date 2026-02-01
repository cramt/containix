# Base module: core options that map directly to mkS6RcImage arguments.
{ lib, pkgs, config, ... }:

{
  options = {
    image = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "OCI image name.";
      };

      tag = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OCI image tag. Defaults to a nix content hash.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "1000:1000";
        description = "User:group the container runs as (OCI User metadata).";
      };

      users = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            uid = lib.mkOption { type = lib.types.int; };
            gid = lib.mkOption { type = lib.types.int; };
            home = lib.mkOption {
              type = lib.types.str;
              default = "/nonexistent";
            };
            shell = lib.mkOption {
              type = lib.types.str;
              default = "/bin/sh";
            };
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
          };
        });
        default = {
          root = { uid = 0; gid = 0; home = "/root"; shell = "/bin/sh"; };
          nobody = { uid = 65534; gid = 65534; home = "/nonexistent"; shell = "/usr/sbin/nologin"; };
        };
        description = "Users to create in /etc/passwd.";
      };

      groups = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            gid = lib.mkOption { type = lib.types.int; };
          };
        });
        default = {
          root = { gid = 0; };
          nogroup = { gid = 65534; };
          nobody = { gid = 65534; };
        };
        description = "Groups to create in /etc/group.";
      };

      labels = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        description = "OCI image labels (e.g. maintainer, version, source URL).";
        example = {
          "org.opencontainers.image.source" = "https://github.com/cramt/containix";
          "org.opencontainers.image.version" = "1.0.0";
        };
      };

      exposedPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
        description = "Ports to expose in OCI image metadata (EXPOSE).";
        example = [ 80 443 8080 ];
      };

      volumes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Volume mount points to declare in OCI image metadata.";
        example = [ "/data" "/var/log" ];
      };

      healthcheck = {
        enable = lib.mkEnableOption "OCI healthcheck";

        command = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Healthcheck command to run inside the container.";
          example = "curl -sf http://localhost:8080/health";
        };

        interval = lib.mkOption {
          type = lib.types.str;
          default = "30s";
          description = "Time between healthcheck runs (Go duration, e.g. 30s, 1m).";
        };

        timeout = lib.mkOption {
          type = lib.types.str;
          default = "10s";
          description = "Max time a healthcheck can run before being killed.";
        };

        retries = lib.mkOption {
          type = lib.types.int;
          default = 3;
          description = "Number of consecutive failures before marking unhealthy.";
        };

        startPeriod = lib.mkOption {
          type = lib.types.str;
          default = "5s";
          description = "Grace period after start before healthchecks count.";
        };
      };

      shell = lib.mkOption {
        type = lib.types.package;
        default = pkgs.bash;
        defaultText = lib.literalExpression "pkgs.bash";
        description = "The package providing /bin/sh (must have /bin/sh or /bin/bash).";
      };

      basePackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ pkgs.coreutils ];
        defaultText = lib.literalExpression "[ pkgs.coreutils ]";
        description = "Packages whose binaries are symlinked into /usr/bin.";
      };
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables set in the container.";
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Packages whose /bin/* are symlinked into /usr/local/bin.";
    };

    copyToRoot = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Extra store paths copied into the image rootfs.";
    };

    files = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.path;
            description = "Source path (file or directory).";
          };
          target = lib.mkOption {
            type = lib.types.str;
            description = "Target path inside the image (relative to /).";
          };
        };
      });
      default = [];
      description = "Extra files to copy into the image.";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          file = lib.mkOption {
            type = lib.types.str;
            description = "Path where the secret file is mounted at runtime.";
            default = "/run/secrets/${name}";
          };

          envVar = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              If set, an init script will read the secret file and export its
              contents as this environment variable via s6 contenv.
            '';
          };
        };
      }));
      default = {};
      description = ''
        Runtime secrets expected to be mounted into the container.
        Compatible with Docker secrets (/run/secrets/), Kubernetes secret
        volumes, and Podman secrets. Each secret declares a file path and
        optionally an environment variable to populate from it.
      '';
      example = {
        db-password = {
          file = "/run/secrets/db-password";
          envVar = "DATABASE_PASSWORD";
        };
        api-key = {
          file = "/run/secrets/api-key";
          envVar = "API_KEY";
        };
      };
    };

    initScripts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Named init scripts that run as oneshot s6-rc services before all other
        services start. Use for directory creation, permission fixes, config
        templating, etc. Each script runs with contenv (environment variables
        are available).
      '';
      example = {
        setup-dirs = ''
          mkdir -p /data/logs /data/cache
          chown 1000:1000 /data/logs /data/cache
        '';
      };
    };

    # NixOS-compatible assertions. Service modules can append to this list.
    # Each assertion is { assertion = bool; message = "..."; }.
    # Evaluated at build time; failing assertions abort with a clear error.
    assertions = lib.mkOption {
      type = lib.types.listOf lib.types.unspecified;
      default = [];
      internal = true;
      description = "List of { assertion, message } checked at evaluation time.";
    };

    # NixOS-compatible warnings. Collected and printed but don't abort.
    warnings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      description = "List of warning messages printed during evaluation.";
    };

    # Internal option: service modules append to this.
    # Maps directly to mkS6RcImage's `services` argument.
    s6Services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          kind = lib.mkOption {
            type = lib.types.enum [ "longrun" "oneshot" ];
            default = "longrun";
            description = "s6-rc service type.";
          };
          run = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Run script body (longrun).";
          };
          up = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Up script body (oneshot).";
          };
          down = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Down script body (oneshot, optional).";
          };
          after = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Services this one depends on.";
          };
        };
      });
      default = {};
      description = "s6-rc service definitions. Populated by service modules.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !config.image.healthcheck.enable || config.image.healthcheck.command != "";
        message = "image.healthcheck.enable is true but image.healthcheck.command is empty.";
      }
    ];
  };
}
