# services.prometheus-node-exporter – Prometheus metrics exporter sidecar.
#
# Exports host/container metrics (CPU, memory, disk, network) in
# Prometheus format. Run as a sidecar alongside your application
# for monitoring.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.prometheus-node-exporter;

  collectorFlags = lib.concatStringsSep " " (
    (map (c: "--collector.${c}") cfg.enabledCollectors)
    ++ (map (c: "--no-collector.${c}") cfg.disabledCollectors)
  );

in
{
  options.services.prometheus-node-exporter = {
    enable = lib.mkEnableOption "Prometheus node exporter";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.prometheus-node-exporter;
      description = "The prometheus-node-exporter package to use.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9100;
      description = "Port to listen on for metrics scraping.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to listen on.";
    };

    metricsPath = lib.mkOption {
      type = lib.types.str;
      default = "/metrics";
      description = "Path under which to expose metrics.";
    };

    enabledCollectors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Additional collectors to enable.";
      example = [ "systemd" "processes" ];
    };

    disabledCollectors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Collectors to disable.";
      example = [ "wifi" "mdadm" "infiniband" ];
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra command-line flags for node_exporter.";
      example = [ "--collector.textfile.directory=/var/lib/node_exporter" ];
    };
  };

  config = lib.mkIf cfg.enable {
    image.exposedPorts = lib.mkDefault [ cfg.port ];

    packages = [ cfg.package ];

    s6Services.prometheus-node-exporter = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/node_exporter \
          --web.listen-address=${cfg.listenAddress}:${toString cfg.port} \
          --web.telemetry-path=${cfg.metricsPath} \
          ${collectorFlags} \
          ${lib.concatStringsSep " " cfg.extraFlags}
      '';
    };
  };
}
