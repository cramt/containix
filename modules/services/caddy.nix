# services.caddy – Caddy web server with Caddyfile generation.
#
# Generates a Caddyfile from structured virtualHosts options,
# similar to the NixOS caddy module.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.caddy;

  vhostOptions = { name, ... }: {
    options = {
      hostName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Canonical hostname for this site.";
      };

      serverAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional hostnames for this site.";
      };

      listenAddresses = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Addresses to bind to for this vhost.";
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra Caddyfile directives for this site block.";
      };

      logFormat = lib.mkOption {
        type = lib.types.nullOr lib.types.lines;
        default = null;
        description = "Log directive contents. Set to null to disable.";
      };
    };
  };

  mkVHostConf = vhost:
    ''
      ${vhost.hostName} ${lib.concatStringsSep " " vhost.serverAliases} {
        ${lib.optionalString (vhost.listenAddresses != [])
          "bind ${lib.concatStringsSep " " vhost.listenAddresses}"}
        ${lib.optionalString (vhost.logFormat != null) ''
          log {
            ${vhost.logFormat}
          }
        ''}
        ${vhost.extraConfig}
      }
    '';

  caddyfile = pkgs.writeText "Caddyfile" ''
    {
      ${lib.optionalString (cfg.email != null) "email ${cfg.email}"}
      ${lib.optionalString (cfg.acmeCA != null) "acme_ca ${cfg.acmeCA}"}
      ${cfg.globalConfig}
    }
    ${cfg.extraConfig}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: mkVHostConf) cfg.virtualHosts)}
  '';

in
{
  options.services.caddy = {
    enable = lib.mkEnableOption "Caddy web server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.caddy;
      description = "The caddy package to use.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/data/caddy";
      description = "Data directory for Caddy (TLS certs, etc).";
    };

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/caddy-logs";
      description = "Log directory for Caddy access logs.";
    };

    email = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Email for ACME account registration.";
    };

    acmeCA = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://acme-staging-v02.api.letsencrypt.org/directory";
      description = "ACME CA directory URL. Null for Caddy's default (Let's Encrypt + ZeroSSL).";
    };

    globalConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines in the Caddyfile global options block.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra Caddyfile content outside of site blocks.";
    };

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule vhostOptions);
      default = {};
      description = "Virtual host definitions.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Override with a custom Caddyfile. If set, virtualHosts/extraConfig are ignored.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];

    files = [
      {
        source = if cfg.configFile != null then cfg.configFile else caddyfile;
        target = "etc/caddy/Caddyfile";
      }
    ];

    s6Services.caddy = {
      kind = "longrun";
      run = ''
        mkdir -p ${cfg.dataDir} ${cfg.logDir}
        export XDG_DATA_HOME=${cfg.dataDir}
        export XDG_CONFIG_HOME=${cfg.dataDir}/config
        exec ${cfg.package}/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
      '';
    };
  };
}
