# services.grafana-alloy – Grafana Alloy metrics agent as an s6-rc longrun.
#
# Alloy scrapes prometheus targets, runs exporters, and remote-writes metrics.
# The config file is a raw .alloy file -- either provided directly or generated
# from structured options (scrape jobs, remote-write endpoints, postgres exporter).
{ lib, pkgs, config, ... }:

let
  cfg = config.services.grafana-alloy;

  # Build custom queries YAML for the postgres exporter.
  customQueriesFile = pkgs.writeText "alloy-custom-queries.yaml"
    (builtins.toJSON cfg.postgres.customQueries);

  # If the user provides a raw config file, use it. Otherwise generate one.
  alloyConfigFile =
    if cfg.configFile != null
    then cfg.configFile
    else pkgs.writeText "main.alloy" cfg.configText;
in
{
  options.services.grafana-alloy = {
    enable = lib.mkEnableOption "Grafana Alloy metrics agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.grafana-alloy;
      description = "The grafana-alloy package to use.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a raw .alloy config file. If set, configText is ignored.
        Environment variable interpolation (sys.env) works at runtime.
      '';
    };

    configText = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Raw Alloy config text. Used when configFile is null.
      '';
    };

    postgres = {
      customQueries = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = ''
          Custom SQL queries for the postgres exporter, as an attrset.
          Serialized to JSON/YAML and passed via CUSTOM_QUERIES_CONFIG_PATH.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];

    environment = lib.mkIf (cfg.postgres.customQueries != {}) {
      CUSTOM_QUERIES_CONFIG_PATH = "${customQueriesFile}";
    };

    files."etc/alloy/main.alloy".source = alloyConfigFile;

    s6Services.grafana-alloy = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/alloy run /etc/alloy/main.alloy
      '';
    };
  };
}
