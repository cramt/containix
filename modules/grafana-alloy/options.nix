{
  lib,
  config,
  ...
}: {
  options.grafana-alloy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    prometheus = lib.mkOption {
      default = {
        remote-write = {};
        scrape = {};
      };
      type = lib.types.submodule {
        options = {
          remote-write = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                url = lib.mkOption {
                  type = lib.types.str;
                  example = "https://my.prometheus.url";
                };
                headers = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = {};
                };
              };
            });
            default = {};
          };
          scrape = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                interval = lib.mkOption {
                  type = lib.types.ints.unsigned;
                  default = 30;
                  example = 100;
                };
                timeout = lib.mkOption {
                  type = lib.types.ints.unsigned;
                  default = 4;
                  example = 10;
                };
                exporter = lib.mkOption {
                  type = lib.types.oneOf [
                    (lib.types.submodule {
                      options = {
                        type = lib.mkOption {
                          type = lib.types.oneOf ["postgres"];
                        };
                        data-source-names = lib.mkOption {
                          type = lib.types.listOf lib.types.str;
                          default = [];
                        };
                        disable-settings-metrics = lib.mkOption {
                          type = lib.types.bool;
                          default = false;
                        };
                        disable-default-metrics = lib.mkOption {
                          type = lib.types.bool;
                          default = false;
                        };
                        custom-queries = lib.mkOption {
                          type = lib.types.attrsOf (lib.types.submodule {
                            options = {
                              query = lib.mkOption {
                                type = lib.types.str;
                              };
                              metrics = lib.mkOption {
                                type = lib.types.attrsOf (lib.types.submodule {
                                  options = {
                                    usage = lib.mkOption {
                                      type = lib.types.oneOf ["LABEL" "HISTOGRAM" "GAUGE" "COUNTER"];
                                    };
                                    description = lib.mkOption {
                                      type = lib.types.str;
                                    };
                                  };
                                });
                              };
                            };
                          });
                          default = {};
                        };
                      };
                    })
                    (lib.types.submodule {
                      options = {
                        type = lib.mkOption {
                          type = lib.types.oneOf ["raw"];
                        };
                        instance = lib.mkOption {
                          type = lib.types.str;
                        };
                        address = lib.mkOption {
                          type = lib.types.str;
                          example = "localhost:9394";
                        };
                        metrics-path = lib.mkOption {
                          type = lib.types.str;
                          default = "/metrics";
                          example = "/path";
                        };
                        schema = lib.mkOption {
                          type = lib.types.str;
                          default = "http";
                          example = "https";
                        };
                      };
                    })
                  ];
                };
                forwards = let
                  options = builtins.attrNames config.prometheus.remote-write;
                in
                  lib.mkOption {
                    type = lib.types.listOf (lib.types.oneOf options);
                    default = options;
                  };
              };
            });
            default = {};
          };
        };
      };
    };
  };
}
