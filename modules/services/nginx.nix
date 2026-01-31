# services.nginx – nginx with NixOS-style virtualHosts/locations/upstreams.
#
# Config generation adapted from the NixOS nginx module.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.nginx;

  # --- location options submodule ---
  locationOptions = { ... }: {
    options = {
      proxyPass = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://localhost:3000";
        description = "Proxy requests to this URL.";
      };

      proxyWebsockets = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable websocket proxying.";
      };

      root = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Root directory for this location.";
      };

      alias = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Alias directory for this location.";
      };

      index = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "index.html index.htm";
        description = "Index directive.";
      };

      tryFiles = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "$uri $uri/ =404";
        description = "try_files directive.";
      };

      return = lib.mkOption {
        type = lib.types.nullOr (lib.types.oneOf [ lib.types.str lib.types.int ]);
        default = null;
        example = "301 https://$host$request_uri";
        description = "Return directive for redirects etc.";
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra config lines appended to this location block.";
      };

      recommendedProxySettings = lib.mkOption {
        type = lib.types.bool;
        default = cfg.recommendedProxySettings;
        description = "Include recommended proxy headers when proxyPass is set.";
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "Order of this location block (lower = earlier).";
      };
    };
  };

  # --- virtualHost options submodule ---
  vhostOptions = { name, ... }: {
    options = {
      serverName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Server name. Defaults to the attribute name.";
      };

      serverAliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional server names.";
      };

      listen = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            addr = lib.mkOption { type = lib.types.str; description = "Listen address."; };
            port = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; description = "Listen port."; };
            ssl = lib.mkOption { type = lib.types.bool; default = false; description = "Enable SSL on this listener."; };
            extraParameters = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Extra listen parameters."; };
          };
        });
        default = [];
        description = "Listen directives. If empty, uses default listen settings.";
      };

      root = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Document root for this vhost.";
      };

      forceSSL = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Redirect all HTTP to HTTPS.";
      };

      addSSL = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable HTTPS in addition to HTTP.";
      };

      onlySSL = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Only serve HTTPS, no HTTP.";
      };

      sslCertificate = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to SSL certificate.";
      };

      sslCertificateKey = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to SSL certificate key.";
      };

      default = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Make this the default server block.";
      };

      globalRedirect = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Redirect all requests to this hostname.";
      };

      redirectCode = lib.mkOption {
        type = lib.types.ints.between 300 399;
        default = 301;
        description = "HTTP status code for redirects.";
      };

      locations = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule locationOptions);
        default = {};
        description = "Location blocks for this vhost.";
      };

      extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Extra config appended to this server block.";
      };
    };
  };

  # --- config generation ---

  mkListenString = { addr, port ? null, ssl ? false, extraParameters ? [], ... }:
    "listen ${addr}${lib.optionalString (port != null) ":${toString port}"}"
    + lib.optionalString ssl " ssl"
    + lib.optionalString (extraParameters != []) (" " + lib.concatStringsSep " " extraParameters)
    + ";";

  mkLocationBlock = loc:
    ''
      location ${loc.location} {
        ${lib.optionalString (loc.proxyPass != null) "proxy_pass ${loc.proxyPass};"}
        ${lib.optionalString (loc.proxyPass != null && loc.recommendedProxySettings) ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_http_version 1.1;
          proxy_set_header "Connection" "";
        ''}
        ${lib.optionalString loc.proxyWebsockets ''
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection $connection_upgrade;
        ''}
        ${lib.optionalString (loc.root != null) "root ${loc.root};"}
        ${lib.optionalString (loc.alias != null) "alias ${loc.alias};"}
        ${lib.optionalString (loc.index != null) "index ${loc.index};"}
        ${lib.optionalString (loc.tryFiles != null) "try_files ${loc.tryFiles};"}
        ${lib.optionalString (loc.return != null) "return ${toString loc.return};"}
        ${loc.extraConfig}
      }
    '';

  mkLocations = locations:
    lib.concatStringsSep "\n" (
      map mkLocationBlock (
        lib.sort (a: b: a.priority < b.priority)
          (lib.mapAttrsToList (k: v: v // { location = k; }) locations)
      )
    );

  mkUpstreamBlock = name: upstream:
    ''
      upstream ${name} {
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (addr: opts:
            "server ${addr}${lib.concatStringsSep "" (
              lib.mapAttrsToList (k: v:
                if builtins.isBool v
                then (lib.optionalString v " ${k}")
                else " ${k}=${toString v}"
              ) opts
            )};"
          ) upstream.servers
        )}
        ${upstream.extraConfig}
      }
    '';

  mkVhostBlock = vhostName: vhost:
    let
      serverName = if vhost.serverName != null then vhost.serverName else vhostName;
      hasSSL = vhost.onlySSL || vhost.addSSL || vhost.forceSSL;

      defaultListenLines =
        if vhost.listen != [] then vhost.listen
        else
          (lib.optional (!vhost.onlySSL) { addr = "0.0.0.0"; port = cfg.defaultHTTPListenPort; ssl = false; })
          ++ (lib.optional hasSSL { addr = "0.0.0.0"; port = cfg.defaultSSLListenPort; ssl = true; });

      hostListen = if vhost.forceSSL then builtins.filter (x: x.ssl) defaultListenLines else defaultListenLines;
      redirectListen = builtins.filter (x: !x.ssl) defaultListenLines;
    in
    ''
      ${lib.optionalString vhost.forceSSL ''
        server {
          ${lib.concatMapStringsSep "\n    " mkListenString redirectListen}
          server_name ${serverName} ${lib.concatStringsSep " " vhost.serverAliases};
          location / {
            return ${toString vhost.redirectCode} https://$host$request_uri;
          }
        }
      ''}
      server {
        ${lib.concatMapStringsSep "\n    " mkListenString hostListen}
        server_name ${serverName} ${lib.concatStringsSep " " vhost.serverAliases};
        ${lib.optionalString (hasSSL && vhost.sslCertificate != null) ''
          ssl_certificate ${vhost.sslCertificate};
          ssl_certificate_key ${vhost.sslCertificateKey};
        ''}
        ${lib.optionalString (vhost.root != null) "root ${vhost.root};"}
        ${lib.optionalString (vhost.globalRedirect != null) ''
          location / {
            return ${toString vhost.redirectCode} http${lib.optionalString hasSSL "s"}://${vhost.globalRedirect}$request_uri;
          }
        ''}
        ${mkLocations vhost.locations}
        ${vhost.extraConfig}
      }
    '';

  upstreamBlocks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList mkUpstreamBlock cfg.upstreams
  );

  vhostBlocks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList mkVhostBlock cfg.virtualHosts
  );

  nginxConf = pkgs.writeText "nginx.conf" ''
    daemon off;
    worker_processes ${toString cfg.workerProcesses};
    error_log /dev/stderr ${cfg.logLevel};
    pid /tmp/nginx.pid;

    events {
      worker_connections ${toString cfg.workerConnections};
    }

    http {
      include ${cfg.package}/conf/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;

      # Non-root temp paths
      client_body_temp_path /tmp/nginx_client_body;
      proxy_temp_path       /tmp/nginx_proxy;
      fastcgi_temp_path     /tmp/nginx_fastcgi;
      uwsgi_temp_path       /tmp/nginx_uwsgi;
      scgi_temp_path        /tmp/nginx_scgi;

      ${lib.optionalString cfg.recommendedOptimisation ''
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        keepalive_timeout 65;
      ''}

      ${lib.optionalString cfg.recommendedGzipSettings ''
        gzip on;
        gzip_static on;
        gzip_vary on;
        gzip_comp_level 5;
        gzip_min_length 256;
        gzip_proxied expired no-cache no-store private auth;
        gzip_types application/atom+xml application/javascript application/json
                   application/xml application/rss+xml image/svg+xml
                   text/css text/javascript text/plain text/xml;
      ''}

      ${lib.optionalString cfg.recommendedProxySettings ''
        proxy_redirect off;
        proxy_connect_timeout ${cfg.proxyTimeout};
        proxy_send_timeout    ${cfg.proxyTimeout};
        proxy_read_timeout    ${cfg.proxyTimeout};
      ''}

      # Websocket upgrade map
      map $http_upgrade $connection_upgrade {
        default upgrade;
        '''     close;
      }

      client_max_body_size ${cfg.clientMaxBodySize};
      server_tokens ${if cfg.serverTokens then "on" else "off"};

      ${cfg.commonHttpConfig}

      ${upstreamBlocks}

      ${vhostBlocks}

      ${cfg.appendHttpConfig}
    }
  '';

in
{
  options.services.nginx = {
    enable = lib.mkEnableOption "nginx web server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nginx;
      description = "The nginx package to use.";
    };

    workerProcesses = lib.mkOption {
      type = lib.types.either lib.types.ints.positive (lib.types.enum [ "auto" ]);
      default = "auto";
      description = "Number of worker processes.";
    };

    workerConnections = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1024;
      description = "Max simultaneous connections per worker.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "debug" "info" "notice" "warn" "error" "crit" "alert" "emerg" ];
      default = "warn";
      description = "Error log level.";
    };

    defaultHTTPListenPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Default HTTP listen port (8080 for non-root containers).";
    };

    defaultSSLListenPort = lib.mkOption {
      type = lib.types.port;
      default = 8443;
      description = "Default HTTPS listen port.";
    };

    recommendedOptimisation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable sendfile, tcp_nopush, tcp_nodelay, keepalive.";
    };

    recommendedGzipSettings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable gzip compression with sensible defaults.";
    };

    recommendedProxySettings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable recommended proxy timeouts and headers.";
    };

    proxyTimeout = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      description = "Proxy connect/send/read timeout.";
    };

    clientMaxBodySize = lib.mkOption {
      type = lib.types.str;
      default = "10m";
      description = "Maximum allowed size of the client request body.";
    };

    serverTokens = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Show nginx version in headers and error pages.";
    };

    commonHttpConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra config lines in the http block, before vhosts.";
    };

    appendHttpConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra config lines appended to the http block, after vhosts.";
    };

    upstreams = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          servers = lib.mkOption {
            type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [ lib.types.bool lib.types.int lib.types.str ]));
            default = {};
            description = "Upstream server addresses and parameters.";
          };
          extraConfig = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Extra lines in the upstream block.";
          };
        };
      });
      default = {};
      description = "Upstream server groups.";
    };

    virtualHosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule vhostOptions);
      default = {};
      description = "Virtual host definitions.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [ cfg.package ];

    files = [
      { source = nginxConf; target = "etc/nginx/nginx.conf"; }
    ];

    s6Services.nginx = {
      kind = "longrun";
      run = ''
        exec ${cfg.package}/bin/nginx -c /etc/nginx/nginx.conf
      '';
    };
  };
}
