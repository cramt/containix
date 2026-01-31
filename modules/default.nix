# Base module: core options that map directly to mkS6RcImage arguments.
{ lib, ... }:

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
        description = "User:group the container runs as.";
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
}
