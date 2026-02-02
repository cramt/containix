# services.haproxy – TCP/HTTP load balancer.
#
# HAProxy is a high-performance TCP/HTTP load balancer and proxy.
# Use it for load balancing, SSL termination, rate limiting, and
# health-checked backend routing.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.haproxy;

  # Build haproxy.cfg from structured options
  haproxyConf = pkgs.writeText "haproxy.cfg" (
    if cfg.configText != null then cfg.configText
    else ''
      global
        log stdout format raw local0
        maxconn ${toString cfg.maxconn}
        ${lib.optionalString (cfg.user != null) "user ${cfg.user}"}
        ${lib.optionalString (cfg.group != null) "group ${cfg.group}"}
        ${cfg.globalConfig}

      defaults
        log global
        mode ${cfg.defaults.mode}
        timeout connect ${cfg.defaults.timeoutConnect}
        timeout client ${cfg.defaults.timeoutClient}
        timeout server ${cfg.defaults.timeoutServer}
        ${lib.optionalString cfg.defaults.httplog "option httplog"}
        ${lib.optionalString cfg.defaults.dontlognull "option dontlognull"}
        ${cfg.defaults.extraConfig}

      ${lib.optionalString cfg.stats.enable ''
        listen stats
          bind ${cfg.stats.bind}
          mode http
          stats enable
          stats uri ${cfg.stats.uri}
          ${lib.optionalString (cfg.stats.auth != null) "stats auth ${cfg.stats.auth}"}
          stats refresh ${cfg.stats.refresh}
      ''}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: fe: ''
        frontend ${name}
          bind ${fe.bind}
          mode ${fe.mode}
          ${lib.concatMapStringsSep "\n  " (acl: acl) fe.acls}
          ${lib.concatMapStringsSep "\n  " (rule: rule) fe.useBackendRules}
          ${lib.optionalString (fe.defaultBackend != null) "default_backend ${fe.defaultBackend}"}
          ${fe.extraConfig}
      '') cfg.frontends)}

      ${lib.concatStringsSep "\n\n" (lib.mapAttrsToList (name: be: ''
        backend ${name}
          mode ${be.mode}
          balance ${be.balance}
          ${lib.concatMapStringsSep "\n  " (srv: "server ${srv}") be.servers}
          ${lib.optionalString be.httpchk.enable "option httpchk ${be.httpchk.method} ${be.httpchk.uri}"}
          ${be.extraConfig}
      '') cfg.backends)}

      ${cfg.extraConfig}
    ''
  );

in
{
  options.services.haproxy = {
    enable = lib.mkEnableOption "HAProxy load balancer";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.haproxy;
      description = "The HAProxy package to use.";
    };

    maxconn = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Maximum number of concurrent connections.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "User to run HAProxy as (after binding ports).";
    };

    group = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Group to run HAProxy as.";
    };

    globalConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines in the global section.";
    };

    defaults = {
      mode = lib.mkOption {
        type = lib.types.enum [ "http" "tcp" ];
        default = "http";
        description = "Default proxy mode.";
      };

      timeoutConnect = lib.mkOption {
        type = lib.types.str;
        default = "5s";
        description = "Default connection timeout.";
      };

      timeoutClient = lib.mkOption {
        type = lib.types.str;
        default = "50s";
        description = "Default client timeout.";
      };

      timeoutServer = lib.mkOption {
        type = lib.types.str;
        default = "50s";
        description = "Default server timeout.";
      };

      httplog = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable HTTP logging.";
      };

      dontlognull = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Don't log null connections (health checks).";
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra lines in the defaults section.";
      };
    };

    stats = {
      enable = lib.mkEnableOption "HAProxy stats page";

      bind = lib.mkOption {
        type = lib.types.str;
        default = "*:8404";
        description = "Address to bind the stats listener.";
      };

      uri = lib.mkOption {
        type = lib.types.str;
        default = "/stats";
        description = "URI path for the stats page.";
      };

      auth = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "admin:password";
        description = "Basic auth credentials for stats page.";
      };

      refresh = lib.mkOption {
        type = lib.types.str;
        default = "10s";
        description = "Stats page auto-refresh interval.";
      };
    };

    frontends = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          bind = lib.mkOption {
            type = lib.types.str;
            description = "Address and port to bind to.";
            example = "*:80";
          };

          mode = lib.mkOption {
            type = lib.types.enum [ "http" "tcp" ];
            default = "http";
            description = "Proxy mode for this frontend.";
          };

          defaultBackend = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default backend to route to.";
          };

          acls = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "ACL rules.";
            example = [ "acl is_api path_beg /api" ];
          };

          useBackendRules = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "use_backend rules.";
            example = [ "use_backend api_servers if is_api" ];
          };

          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Extra frontend configuration.";
          };
        };
      });
      default = {};
      description = "HAProxy frontend definitions.";
    };

    backends = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          mode = lib.mkOption {
            type = lib.types.enum [ "http" "tcp" ];
            default = "http";
            description = "Proxy mode for this backend.";
          };

          balance = lib.mkOption {
            type = lib.types.str;
            default = "roundrobin";
            description = "Load balancing algorithm.";
          };

          servers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Backend server definitions.";
            example = [ "app1 127.0.0.1:3000 check" "app2 127.0.0.1:3001 check" ];
          };

          httpchk = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable HTTP health checks.";
            };

            method = lib.mkOption {
              type = lib.types.str;
              default = "GET";
              description = "HTTP method for health check.";
            };

            uri = lib.mkOption {
              type = lib.types.str;
              default = "/";
              description = "URI path for health check.";
            };
          };

          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Extra backend configuration.";
          };
        };
      });
      default = {};
      description = "HAProxy backend definitions.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Override with a custom haproxy.cfg. If set, structured options are ignored.";
    };

    configText = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Raw HAProxy configuration text. If set, structured options are ignored.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra configuration appended after all sections.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];

    files = [
      {
        source = if cfg.configFile != null then cfg.configFile else haproxyConf;
        target = "etc/haproxy/haproxy.cfg";
      }
    ];

    s6Services.haproxy = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/haproxy -f /etc/haproxy/haproxy.cfg -W -db
      '';
      # HAProxy uses SIGUSR1 for graceful stop (finish active connections)
      stopSignal = "SIGUSR1";
      stopTimeout = 30000;  # 30s to drain connections
    };
  };
}
