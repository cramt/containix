# services.vector – Log/metrics shipping agent.
#
# Vector is a high-performance observability data pipeline. Use it as a
# sidecar to collect, transform, and ship logs and metrics from your
# container to external systems (Elasticsearch, Loki, Datadog, etc.).
{ lib, pkgs, config, ... }:

let
  cfg = config.services.vector;

  # Build vector.toml from structured options
  vectorConfig = pkgs.writeText "vector.toml" (
    if cfg.configText != null then cfg.configText
    else ''
      # Vector configuration
      # See https://vector.dev/docs/reference/configuration/

      [api]
      enabled = ${if cfg.api.enable then "true" else "false"}
      ${lib.optionalString cfg.api.enable ''address = "${cfg.api.address}"''}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: src: ''
        [sources.${name}]
        ${src}
      '') cfg.sources)}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: xform: ''
        [transforms.${name}]
        ${xform}
      '') cfg.transforms)}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: sink: ''
        [sinks.${name}]
        ${sink}
      '') cfg.sinks)}

      ${cfg.extraConfig}
    ''
  );

in
{
  options.services.vector = {
    enable = lib.mkEnableOption "Vector log/metrics agent";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.vector;
      description = "The Vector package to use.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vector";
      description = "Directory for Vector's persistent data (buffer, checkpoints).";
    };

    api = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Vector's GraphQL API for introspection.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0:8686";
        description = "Address for the Vector API to listen on.";
      };
    };

    sources = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Vector source definitions in TOML format (without the [sources.name] header).
        Each key becomes a source name.
      '';
      example = {
        docker_logs = ''
          type = "docker_logs"
        '';
        stdin = ''
          type = "stdin"
        '';
      };
    };

    transforms = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Vector transform definitions in TOML format (without the [transforms.name] header).
      '';
      example = {
        parse_json = ''
          type = "remap"
          inputs = ["docker_logs"]
          source = ". = parse_json!(.message)"
        '';
      };
    };

    sinks = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Vector sink definitions in TOML format (without the [sinks.name] header).
      '';
      example = {
        stdout = ''
          type = "console"
          inputs = ["docker_logs"]
          encoding.codec = "json"
        '';
      };
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Override with a custom Vector config file. If set, structured options are ignored.";
    };

    configText = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Raw Vector configuration text (TOML). If set, sources/transforms/sinks are ignored.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra TOML configuration appended to the generated config.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];

    files = [
      {
        source = if cfg.configFile != null then cfg.configFile else vectorConfig;
        target = "etc/vector/vector.toml";
      }
    ];

    s6Services.vector = {
      kind = "longrun";
      run = ''
        mkdir -p ${cfg.dataDir}
        export VECTOR_DATA_DIR=${cfg.dataDir}
        exec ${cfg.package}/bin/vector --config /etc/vector/vector.toml
      '';
    };
  };
}
