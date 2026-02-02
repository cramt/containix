# services.unbound – Recursive DNS resolver.
#
# Unbound is a validating, recursive, caching DNS resolver. Use it
# for DNSSEC validation, local DNS resolution, or as a privacy-focused
# DNS resolver in your container network.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.unbound;

  # Build unbound.conf from structured options
  unboundConf = pkgs.writeText "unbound.conf" ''
    server:
      verbosity: ${toString cfg.verbosity}
      interface: ${cfg.listenAddress}
      port: ${toString cfg.port}
      do-ip4: ${if cfg.enableIPv4 then "yes" else "no"}
      do-ip6: ${if cfg.enableIPv6 then "yes" else "no"}
      do-udp: yes
      do-tcp: yes

      # Access control
      ${lib.concatMapStringsSep "\n  " (acl: "access-control: ${acl}") cfg.accessControl}

      # DNSSEC
      ${lib.optionalString cfg.dnssec.enable ''
      auto-trust-anchor-file: "/etc/unbound/root.key"
      ''}

      # Cache settings
      msg-cache-size: ${cfg.cache.msgCacheSize}
      rrset-cache-size: ${cfg.cache.rrsetCacheSize}
      ${lib.optionalString (cfg.cache.minTtl != null) "cache-min-ttl: ${toString cfg.cache.minTtl}"}
      ${lib.optionalString (cfg.cache.maxTtl != null) "cache-max-ttl: ${toString cfg.cache.maxTtl}"}
      ${lib.optionalString cfg.cache.prefetch "prefetch: yes"}

      # Performance
      num-threads: ${toString cfg.numThreads}
      ${lib.optionalString cfg.soReuseport "so-reuseport: yes"}

      # Privacy
      ${lib.optionalString cfg.hideIdentity "hide-identity: yes"}
      ${lib.optionalString cfg.hideVersion "hide-version: yes"}
      ${lib.optionalString cfg.qnameMinimisation "qname-minimisation: yes"}

      # Logging
      ${lib.optionalString cfg.logQueries "log-queries: yes"}
      use-syslog: no
      logfile: ""

      # Local data
      ${lib.concatMapStringsSep "\n  " (d: ''local-data: "${d}"'') cfg.localData}
      ${lib.concatMapStringsSep "\n  " (z: "local-zone: ${z}") cfg.localZones}

      ${cfg.serverConfig}

    ${lib.optionalString (cfg.forwardZones != {}) (
      lib.concatStringsSep "\n" (lib.mapAttrsToList (zone: fwd: ''
        forward-zone:
          name: "${zone}"
          ${lib.concatMapStringsSep "\n  " (s: "forward-addr: ${s}") fwd.forwardAddrs}
          ${lib.optionalString fwd.forwardTlsUpstream "forward-tls-upstream: yes"}
      '') cfg.forwardZones)
    )}

    ${lib.optionalString (cfg.stubZones != {}) (
      lib.concatStringsSep "\n" (lib.mapAttrsToList (zone: stub: ''
        stub-zone:
          name: "${zone}"
          ${lib.concatMapStringsSep "\n  " (s: "stub-addr: ${s}") stub.stubAddrs}
      '') cfg.stubZones)
    )}

    ${cfg.extraConfig}
  '';

in
{
  options.services.unbound = {
    enable = lib.mkEnableOption "Unbound DNS resolver";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.unbound;
      description = "The Unbound package to use.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 53;
      description = "Port to listen on.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to listen on.";
    };

    enableIPv4 = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable IPv4 support.";
    };

    enableIPv6 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable IPv6 support.";
    };

    accessControl = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "0.0.0.0/0 allow" "::0/0 allow" ];
      description = "Access control rules (CIDR action).";
      example = [ "10.0.0.0/8 allow" "127.0.0.0/8 allow" "0.0.0.0/0 refuse" ];
    };

    verbosity = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Verbosity level (0-5).";
    };

    numThreads = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of threads to use.";
    };

    soReuseport = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use SO_REUSEPORT for better multi-thread performance.";
    };

    dnssec = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable DNSSEC validation.";
      };
    };

    cache = {
      msgCacheSize = lib.mkOption {
        type = lib.types.str;
        default = "4m";
        description = "Size of the message cache.";
      };

      rrsetCacheSize = lib.mkOption {
        type = lib.types.str;
        default = "4m";
        description = "Size of the RRset cache.";
      };

      minTtl = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Minimum TTL for cached records (seconds).";
      };

      maxTtl = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Maximum TTL for cached records (seconds).";
      };

      prefetch = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Prefetch almost-expired cache entries.";
      };
    };

    hideIdentity = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Hide server identity (id.server, hostname.bind).";
    };

    hideVersion = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Hide server version (version.server, version.bind).";
    };

    qnameMinimisation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable QNAME minimisation for privacy.";
    };

    logQueries = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Log all DNS queries.";
    };

    localData = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Local DNS data entries.";
      example = [ "myhost.local. IN A 192.168.1.100" ];
    };

    localZones = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Local zone declarations.";
      example = [ ''"local." static'' ];
    };

    forwardZones = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          forwardAddrs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Addresses to forward queries to.";
          };
          forwardTlsUpstream = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Use DNS-over-TLS for forwarding.";
          };
        };
      });
      default = {};
      description = "Forward zone configurations.";
      example = {
        "." = {
          forwardAddrs = [ "1.1.1.1@853" "1.0.0.1@853" ];
          forwardTlsUpstream = true;
        };
      };
    };

    stubZones = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          stubAddrs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Addresses of authoritative servers for this zone.";
          };
        };
      });
      default = {};
      description = "Stub zone configurations.";
    };

    serverConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines in the server: section.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Override with a custom unbound.conf. If set, structured options are ignored.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra configuration appended to unbound.conf.";
    };
  };

  config = lib.mkIf cfg.enable {
    image.exposedPorts = lib.mkDefault [ cfg.port ];

    packages = [ cfg.package ];

    files."etc/unbound/unbound.conf".source =
      if cfg.configFile != null then cfg.configFile else unboundConf;

    # Generate DNSSEC root trust anchor if DNSSEC is enabled
    initScripts = lib.mkIf cfg.dnssec.enable {
      unbound-anchor = ''
        mkdir -p /etc/unbound
        ${cfg.package}/bin/unbound-anchor -a /etc/unbound/root.key || true
      '';
    };

    s6Services.unbound = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/unbound -d -c /etc/unbound/unbound.conf
      '';
    };
  };
}
