{
  lib,
  config,
  pkgs,
  ...
}: let
  cfg = config.grafana-alloy;

  custom-queries-packages = builtins.mapAttrs (n: v:
    pkgs.writeTextFile {
      name = "grafana-alloy-postgres-custom-query-${n}";
      text = builtins.toJSON v.exporter.custom-queries;
      destination = "/main.yaml";
    }) (lib.attrsets.filterAttrs (n: v: v.exporter.type == "postgres") cfg.prometheus.scrape);
  configTextList =
    (lib.attrsets.mapAttrsToList (name: {
        url,
        headers,
      }: ''
        prometheus.remote_write "${name}" {
            endpoint {
                url = "${url}"
                headers = ${builtins.toJSON headers}
            }
        }
      '')
      cfg.prometheus.remote-write)
    ++ (
      lib.attrsets.mapAttrsToList (name: {
        interval,
        timeout,
        exporter,
        forwards,
      }: ''
        ${
          if exporter.type == "postgres"
          then ''
            prometheus.exporter.postgres "${name}" {
                data_source_names = ${builtins.toJSON exporter.data-source-names}
                disable_settings_metrics = ${builtins.toJSON exporter.disable-settings-metrics}
                disable_default_metrics = ${builtins.toJSON exporter.disable-default-metrics}
                custom_queries_config_path = "${custom-queries-packages.${name}}/main.yaml"
            }
          ''
          else ""
        }

        prometheus.scrape "${name}" {
            scrape_interval = "${interval}s"
            scrape_timeout  = "${timeout}s"

            targets    = ${
          if exporter.type != "raw"
          then
            builtins.toJSON [
              {
                __address__ = exporter.address;
                __metrics_path__ = exporter.metrics-path;
                __scheme__ = exporter.scheme;
                instance = exporter.instance;
              }
            ]
          else "prometheus.exporter.${exporter.type}.${name}.targets"
        }
            forward_to = [${lib.strings.concatStringsSep "," (builtins.map (x: "prometheus.remote_write.${x}.receiver") forwards)}]
        }
      '')
      cfg.prometheus.scrape
    );
  alloyConfig = pkgs.writeTextFile {
    name = "grafana-alloy-config";
    text = lib.strings.concatStringsSep "\n" configTextList;
    destination = "/main.alloy";
  };
  main = pkgs.writeShellApplication {
    name = "grafana-alloy";

    runtimeInputs = with pkgs; [grafana-alloy envsubst busybox];
    text = ''
      FILE=$(mktemp)
      export FILE
      envsubst < ${alloyConfig}/main.alloy > "$FILE"
      alloy run "$FILE" > /dev/null
    '';
  };
in {
  imports = [./options.nix];
  config = lib.mkIf cfg.enable {
    packages = [alloyConfig] ++ builtins.attrValues custom-queries-packages;
    entrypoints = [
      main
    ];
  };
}
