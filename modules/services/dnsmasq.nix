# services.dnsmasq – Lightweight DNS/DHCP sidecar.
#
# Useful as a DNS cache, local resolver, or DHCP server in container
# networks. Commonly used as a sidecar for service discovery or
# split-horizon DNS.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.dnsmasq;

  # Build dnsmasq.conf from structured options
  dnsmasqConf = pkgs.writeText "dnsmasq.conf" ''
    # Listen settings
    port=${toString cfg.port}
    ${lib.optionalString (cfg.listenAddress != null) "listen-address=${cfg.listenAddress}"}
    ${lib.optionalString (!cfg.bindInterfaces) "bind-dynamic"}
    ${lib.optionalString cfg.bindInterfaces "bind-interfaces"}

    # DNS settings
    ${lib.optionalString (!cfg.domainNeeded) "domain-needed"}
    ${lib.optionalString (!cfg.bogusPriv) "bogus-priv"}
    ${lib.optionalString (cfg.cacheSize > 0) "cache-size=${toString cfg.cacheSize}"}
    ${lib.optionalString cfg.noNegcache "no-negcache"}
    ${lib.optionalString cfg.noResolv "no-resolv"}
    ${lib.optionalString cfg.noHosts "no-hosts"}

    # Upstream servers
    ${lib.concatMapStringsSep "\n" (s: "server=${s}") cfg.servers}

    # Static DNS records
    ${lib.concatMapStringsSep "\n" (r: "address=/${r.name}/${r.address}") cfg.addresses}

    # DHCP settings
    ${lib.optionalString (cfg.dhcp.enable) ''
      dhcp-range=${cfg.dhcp.range}
      ${lib.optionalString (cfg.dhcp.leasetime != null) "dhcp-lease-max=${cfg.dhcp.leasetime}"}
      ${lib.optionalString (cfg.dhcp.gateway != null) "dhcp-option=3,${cfg.dhcp.gateway}"}
      ${lib.optionalString (cfg.dhcp.dns != null) "dhcp-option=6,${cfg.dhcp.dns}"}
    ''}

    # Logging
    ${lib.optionalString cfg.logQueries "log-queries"}
    ${lib.optionalString cfg.logDhcp "log-dhcp"}

    # Keep in foreground (required for s6)
    keep-in-foreground

    ${cfg.extraConfig}
  '';

in
{
  options.services.dnsmasq = {
    enable = lib.mkEnableOption "dnsmasq DNS/DHCP server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dnsmasq;
      description = "The dnsmasq package to use.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 53;
      description = "DNS port to listen on.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "127.0.0.1";
      description = "Address to listen on. Null means all interfaces.";
    };

    bindInterfaces = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Bind only to specified interfaces (use bind-interfaces instead of bind-dynamic).";
    };

    servers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "8.8.8.8" "8.8.4.4" ];
      description = "Upstream DNS servers.";
      example = [ "1.1.1.1" "1.0.0.1" ];
    };

    addresses = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Domain name to resolve.";
            example = "myapp.local";
          };
          address = lib.mkOption {
            type = lib.types.str;
            description = "IP address to return.";
            example = "127.0.0.1";
          };
        };
      });
      default = [];
      description = "Static DNS address records.";
    };

    cacheSize = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "DNS cache size (0 to disable).";
    };

    noNegcache = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable negative caching.";
    };

    noResolv = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Don't read /etc/resolv.conf for upstream servers.";
    };

    noHosts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Don't read /etc/hosts.";
    };

    domainNeeded = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Don't forward plain names (without dots) upstream.";
    };

    bogusPriv = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Don't forward reverse lookups for private ranges upstream.";
    };

    logQueries = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Log DNS queries to stderr.";
    };

    logDhcp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Log DHCP transactions to stderr.";
    };

    dhcp = {
      enable = lib.mkEnableOption "DHCP server";

      range = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "192.168.1.50,192.168.1.150,12h";
        description = "DHCP range (start,end[,leasetime]).";
      };

      leasetime = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Maximum number of DHCP leases.";
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default gateway to advertise via DHCP.";
      };

      dns = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "DNS server to advertise via DHCP.";
      };
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Override with a custom dnsmasq.conf. If set, structured options are ignored.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra lines appended to dnsmasq.conf.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.dhcp.enable || cfg.dhcp.range != "";
        message = "services.dnsmasq: dhcp.enable is true but dhcp.range is empty.";
      }
    ];

    image.exposedPorts = lib.mkDefault [ cfg.port ];

    packages = [ cfg.package ];

    files."etc/dnsmasq.conf".source =
      if cfg.configFile != null then cfg.configFile else dnsmasqConf;

    s6Services.dnsmasq = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/dnsmasq --keep-in-foreground --log-facility=- --conf-file=/etc/dnsmasq.conf
      '';
    };
  };
}
