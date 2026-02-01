{
  description = "containix – a mini NixOS for containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nix2container = {
      inputs.nixpkgs.follows = "nixpkgs";
      url = "github:nlewo/nix2container";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    nix2container,
    ...
  }:
    {
      templates.default = {
        path = ./templates/default;
        description = "A basic containix container with nginx";
      };
    } //
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;
      nix2containerPkgs = nix2container.packages.${system};

      # npins sources – read the raw JSON so we get url+hash for fetchurl,
      # rather than using npins' default.nix which unpacks tarballs.
      sources = (builtins.fromJSON (builtins.readFile ./npins/sources.json)).pins;

      mkS6RcImage = import ./mk-s6rc-image.nix { inherit pkgs nix2containerPkgs sources; };

      # Auto-discover service modules from modules/services/
      serviceModuleDir = ./modules/services;
      serviceModules =
        lib.optionalAttrs (builtins.pathExists serviceModuleDir)
          (builtins.readDir serviceModuleDir);
      serviceModuleList =
        lib.mapAttrsToList
          (name: _: import (serviceModuleDir + "/${name}"))
          serviceModules;

      # All modules: base + all service modules
      allModules = [ ./modules/default.nix ] ++ serviceModuleList;

      # mkContainer :: config -> image derivation
      # Evaluates the module system and calls mkS6RcImage with the result.
      mkContainer = config: let
        rawConfig = (lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = allModules ++ [
            ({ ... }: config)
          ];
        }).config;

        # Check assertions (NixOS-style).
        failedAssertions = builtins.filter (a: !a.assertion) rawConfig.assertions;
        assertionMessages = builtins.map (a: a.message) failedAssertions;

        # Abort if any assertions fail; print warnings otherwise.
        evaluated =
          if failedAssertions != [] then
            throw "containix: Failed assertions:\n${lib.concatStringsSep "\n" (map (m: "- ${m}") assertionMessages)}"
          else if rawConfig.warnings != [] then
            builtins.trace "containix warnings:\n${lib.concatStringsSep "\n" (map (m: "- ${m}") rawConfig.warnings)}" rawConfig
          else rawConfig;
      in
        let
          # Secrets that need contenv integration (file -> env var).
          secretsWithEnv = lib.filterAttrs (_: s: s.envVar != null) evaluated.secrets;
          hasSecrets = secretsWithEnv != {};

          # Generate a oneshot that reads secret files into s6 contenv dir
          # so they become environment variables for all services.
          secretsInitScript = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: secret: ''
            if [ -f "${secret.file}" ]; then
              cat "${secret.file}" > /run/s6/container_environment/${secret.envVar}
            else
              echo "containix: warning: secret file '${secret.file}' not found" >&2
            fi
          '') secretsWithEnv);

          secretsService = lib.optionalAttrs hasSecrets {
            "init-secrets" = {
              kind = "oneshot";
              after = [];
              up = ''
                mkdir -p /run/s6/container_environment
                ${secretsInitScript}
              '';
            };
          };

          # Merge user-defined s6Services with auto-generated initScript services.
          # Each initScript becomes a oneshot service named "init-<name>" that all
          # other services implicitly depend on.
          initServiceNames =
            (lib.mapAttrsToList (name: _: "init-${name}") evaluated.initScripts)
            ++ (lib.optional hasSecrets "init-secrets");
          initServices = lib.mapAttrs' (name: script:
            lib.nameValuePair "init-${name}" {
              kind = "oneshot";
              after = if hasSecrets then [ "init-secrets" ] else [];
              up = script;
            }
          ) evaluated.initScripts;

          # Add initScript dependencies to all user-defined services.
          userServices = lib.mapAttrs (_: svc:
            { inherit (svc) kind;
              after = svc.after ++ initServiceNames;
            }
            // lib.optionalAttrs (svc.run != null) { inherit (svc) run; }
            // lib.optionalAttrs (svc.up != null) { inherit (svc) up; }
            // lib.optionalAttrs (svc.down != null) { inherit (svc) down; }
          ) evaluated.s6Services;
        in
        mkS6RcImage {
          name = evaluated.image.name;
          tag = evaluated.image.tag;
          user = evaluated.image.user;
          env = evaluated.environment;
          extraPaths = evaluated.packages;
          copyToRoot = evaluated.copyToRoot;
          extraFiles = evaluated.files;
          labels = evaluated.image.labels;
          exposedPorts = evaluated.image.exposedPorts;
          volumes = evaluated.image.volumes;
          healthcheck =
            if evaluated.image.healthcheck.enable then {
              command = evaluated.image.healthcheck.command;
              interval = evaluated.image.healthcheck.interval;
              timeout = evaluated.image.healthcheck.timeout;
              retries = evaluated.image.healthcheck.retries;
              startPeriod = evaluated.image.healthcheck.startPeriod;
            } else null;
          services = secretsService // initServices // userServices;
        };
    in {
      lib = {
        inherit mkS6RcImage mkContainer;
      };

      # Development shell for working on containix itself.
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.npins
          pkgs.nix-output-monitor
        ];
      };

      # ── Integration test images ──────────────────────────────────────
      # These are real, buildable container images used by tests/integration.sh.
      # They exercise actual container behaviour (HTTP responses, env vars, etc.)
      # rather than just evaluating the Nix expressions.
      packages = lib.optionalAttrs (system == "x86_64-linux" || system == "aarch64-linux") {
        # Test 1: nginx serving static HTML
        test-nginx-static = mkContainer {
          image.name = "containix-test-nginx-static";
          image.tag = "test";
          image.user = "root";

          services.nginx = {
            enable = true;
            virtualHosts.localhost.locations."/" = {
              root = "/srv/www";
              index = "index.html";
              tryFiles = "$uri $uri/ =404";
            };
          };

          files = [
            {
              source = pkgs.writeText "index.html" ''
                <!DOCTYPE html><html><body>CONTAINIX_TEST_OK</body></html>
              '';
              target = "srv/www/index.html";
            }
          ];
        };

        # Test 2: reverse proxy with upstream + health endpoint
        test-reverse-proxy = let
          app = pkgs.writeShellApplication {
            name = "test-app";
            runtimeInputs = [ pkgs.python3 ];
            text = ''
              cd /tmp
              echo "UPSTREAM_OK" > index.html
              python3 -m http.server 3000
            '';
          };
        in mkContainer {
          image.name = "containix-test-reverse-proxy";
          image.tag = "test";
          image.user = "root";

          packages = [ app ];

          services.nginx = {
            enable = true;
            upstreams.app.servers."127.0.0.1:3000" = {};
            virtualHosts.localhost = {
              locations."/".proxyPass = "http://app";
              locations."/health" = {
                return = "200 healthy";
                extraConfig = "add_header Content-Type text/plain;";
              };
            };
          };

          s6Services.app = {
            kind = "longrun";
            run = "exec test-app";
          };
        };

        # Test 3: environment variables and initScripts
        test-env-init = let
          envServer = pkgs.writeText "env-server.py" ''
            import http.server, os, socketserver

            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    if self.path == "/env":
                        self.wfile.write(("TEST_VAR=" + os.environ.get("TEST_VAR", "MISSING")).encode())
                    elif self.path == "/init":
                        try:
                            with open("/tmp/init-test/marker") as f:
                                self.wfile.write(f.read().strip().encode())
                        except FileNotFoundError:
                            self.wfile.write(b"INIT_NOT_FOUND")
                    else:
                        self.wfile.write(b"ok")
                def log_message(self, *a): pass

            with socketserver.TCPServer(("", 8080), H) as s:
                s.serve_forever()
          '';
        in mkContainer {
          image.name = "containix-test-env-init";
          image.tag = "test";
          image.user = "root";

          environment = {
            TEST_VAR = "hello_from_containix";
            ANOTHER_VAR = "42";
          };

          packages = [ pkgs.python3 ];

          files = [
            { source = envServer; target = "srv/env-server.py"; }
          ];

          initScripts.create-marker = ''
            mkdir -p /tmp/init-test
            echo "INIT_SCRIPT_RAN" > /tmp/init-test/marker
          '';

          s6Services.env-server = {
            kind = "longrun";
            run = "exec python3 /srv/env-server.py";
          };
        };

        # Test 4: OCI metadata (labels, exposed ports)
        test-metadata = mkContainer {
          image.name = "containix-test-metadata";
          image.tag = "test";
          image.user = "root";

          image.labels = {
            "com.containix.test" = "label-value-ok";
            "org.opencontainers.image.source" = "https://github.com/cramt/containix";
          };
          image.exposedPorts = [ 8080 9090 ];
          image.volumes = [ "/data" "/cache" ];

          # Dummy service so the container stays alive
          packages = [ pkgs.coreutils ];
          s6Services.sleeper = {
            kind = "longrun";
            run = "exec sleep infinity";
          };
        };

        # Test 5: caddy serving static content
        test-caddy = mkContainer {
          image.name = "containix-test-caddy";
          image.tag = "test";
          image.user = "root";

          services.caddy = {
            enable = true;
            virtualHosts.":8080" = {
              extraConfig = ''
                respond "CADDY_TEST_OK" 200
              '';
            };
          };
        };

        # Test 6: secrets with contenv integration
        test-secrets = let
          secretServer = pkgs.writeText "secret-server.py" ''
            import http.server, os, socketserver

            class H(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.end_headers()
                    val = os.environ.get("SECRET_VALUE", "MISSING")
                    self.wfile.write(val.encode())
                def log_message(self, *a): pass

            with socketserver.TCPServer(("", 8080), H) as s:
                s.serve_forever()
          '';
        in mkContainer {
          image.name = "containix-test-secrets";
          image.tag = "test";
          image.user = "root";

          secrets.test-secret = {
            file = "/run/secrets/test-secret";
            envVar = "SECRET_VALUE";
          };

          packages = [ pkgs.python3 ];

          files = [
            { source = secretServer; target = "srv/secret-server.py"; }
          ];

          s6Services.secret-server = {
            kind = "longrun";
            run = "exec python3 /srv/secret-server.py";
          };
        };
      };

      # ── Integration test runner ──────────────────────────────────────
      # A self-contained script that loads test images into Docker, runs
      # them, and asserts behaviour.  All deps (curl, jq, docker cli)
      # are provided by Nix; the only external requirement is a running
      # Docker daemon.
      #
      # Usage:  nix run .#integration-test
      apps = lib.optionalAttrs (system == "x86_64-linux" || system == "aarch64-linux") {
        integration-test = let
          images = {
            inherit (self.packages.${system})
              test-nginx-static test-reverse-proxy test-env-init
              test-metadata test-caddy test-secrets;
          };
          copyScripts = lib.mapAttrs (_: img: img.copyToDockerDaemon) images;
          testScript = pkgs.writeShellApplication {
            name = "containix-integration-test";
            runtimeInputs = with pkgs; [ curl jq docker ];
            text = ''
              set -euo pipefail

              # ── copy-to-docker-daemon paths (baked in by Nix) ──
              COPY_NGINX="${copyScripts.test-nginx-static}/bin/copy-to-docker-daemon"
              COPY_RPROXY="${copyScripts.test-reverse-proxy}/bin/copy-to-docker-daemon"
              COPY_ENV="${copyScripts.test-env-init}/bin/copy-to-docker-daemon"
              COPY_META="${copyScripts.test-metadata}/bin/copy-to-docker-daemon"
              COPY_CADDY="${copyScripts.test-caddy}/bin/copy-to-docker-daemon"
              COPY_SECRETS="${copyScripts.test-secrets}/bin/copy-to-docker-daemon"

              # ── helpers ──
              RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
              BOLD=$'\033[1m'; RESET=$'\033[0m'
              PASS=0; FAIL=0; SKIP=0
              FAILURES=()
              CONTAINERS=()

              cleanup() { for c in "''${CONTAINERS[@]}"; do docker rm -f "$c" &>/dev/null || true; done; }
              trap cleanup EXIT

              log()  { echo -e "''${BOLD}[test]''${RESET} $*"; }
              pass() { echo -e "  ''${GREEN}PASS''${RESET} $1"; PASS=$((PASS + 1)); }
              fail() { echo -e "  ''${RED}FAIL''${RESET} $1: $2"; FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); }

              wait_http() {
                local url="$1" max="''${2:-30}" i=0
                while [ "$i" -lt "$max" ]; do
                  if curl -sf -o /dev/null "$url" 2>/dev/null; then return 0; fi
                  sleep 1; i=$((i + 1))
                done
                return 1
              }

              load() { log "Loading $1 ..."; "$2" 2>/dev/null; }

              # ── test: nginx-static ──
              test_nginx_static() {
                local t="nginx-static"
                log "=== $t ==="
                load "$t" "$COPY_NGINX"
                local cid; cid=$(docker run -d --name "cix-nginx-$$" -p 18080:8080 containix-test-nginx-static:test)
                CONTAINERS+=("$cid")
                if ! wait_http "http://localhost:18080" 30; then
                  fail "$t" "not ready in 30s"; docker logs "$cid" 2>&1 | tail -20; return; fi
                local body; body=$(curl -sf http://localhost:18080/)
                if echo "$body" | grep -q "CONTAINIX_TEST_OK"; then pass "$t: serves static HTML"
                else fail "$t: serves static HTML" "got: $body"; fi
                local code; code=$(curl -sf -o /dev/null -w '%{http_code}' http://localhost:18080/)
                if [ "$code" = "200" ]; then pass "$t: HTTP 200"; else fail "$t: HTTP 200" "got $code"; fi
                code=$(curl -o /dev/null -w '%{http_code}' http://localhost:18080/nope 2>/dev/null || true)
                if [ "$code" = "404" ]; then pass "$t: 404 for missing"; else fail "$t: 404 for missing" "got $code"; fi
                docker rm -f "$cid" &>/dev/null || true
              }

              # ── test: reverse-proxy ──
              test_reverse_proxy() {
                local t="reverse-proxy"
                log "=== $t ==="
                load "$t" "$COPY_RPROXY"
                local cid; cid=$(docker run -d --name "cix-rproxy-$$" -p 18081:8080 containix-test-reverse-proxy:test)
                CONTAINERS+=("$cid")
                if ! wait_http "http://localhost:18081/health" 30; then
                  fail "$t" "not ready in 30s"; docker logs "$cid" 2>&1 | tail -20; return; fi
                local body; body=$(curl -sf http://localhost:18081/health)
                if echo "$body" | grep -q "healthy"; then pass "$t: /health ok"
                else fail "$t: /health ok" "got: $body"; fi
                if wait_http "http://localhost:18081/" 15; then
                  body=$(curl -sf http://localhost:18081/)
                  if echo "$body" | grep -q "UPSTREAM_OK"; then pass "$t: proxies to upstream"
                  else fail "$t: proxies to upstream" "got: $body"; fi
                else fail "$t: proxies to upstream" "upstream never reachable"; fi
                docker rm -f "$cid" &>/dev/null || true
              }

              # ── test: env + initScripts ──
              test_env_init() {
                local t="env-init"
                log "=== $t ==="
                load "$t" "$COPY_ENV"
                local cid; cid=$(docker run -d --name "cix-env-$$" -p 18082:8080 containix-test-env-init:test)
                CONTAINERS+=("$cid")
                if ! wait_http "http://localhost:18082/" 30; then
                  fail "$t" "not ready in 30s"; docker logs "$cid" 2>&1 | tail -20; return; fi
                local body; body=$(curl -sf http://localhost:18082/env)
                if [ "$body" = "TEST_VAR=hello_from_containix" ]; then pass "$t: env var set"
                else fail "$t: env var set" "got: $body"; fi
                body=$(curl -sf http://localhost:18082/init)
                if [ "$body" = "INIT_SCRIPT_RAN" ]; then pass "$t: initScript ran"
                else fail "$t: initScript ran" "got: $body"; fi
                docker rm -f "$cid" &>/dev/null || true
              }

              # ── test: OCI metadata ──
              test_metadata() {
                local t="metadata"
                log "=== $t ==="
                load "$t" "$COPY_META"
                local ins; ins=$(docker inspect containix-test-metadata:test)
                if [ -z "$ins" ]; then fail "$t" "inspect failed"; return; fi
                local v
                v=$(echo "$ins" | jq -r '.[0].Config.Labels["com.containix.test"] // "MISSING"')
                if [ "$v" = "label-value-ok" ]; then pass "$t: label set"; else fail "$t: label set" "got: $v"; fi
                v=$(echo "$ins" | jq -r '.[0].Config.ExposedPorts // {} | keys | sort | join(" ")')
                if echo "$v" | grep -q "8080/tcp" && echo "$v" | grep -q "9090/tcp"; then pass "$t: exposed ports"
                else fail "$t: exposed ports" "got: $v"; fi
                v=$(echo "$ins" | jq -r '.[0].Config.Volumes // {} | keys | sort | join(" ")')
                if echo "$v" | grep -q "/data" && echo "$v" | grep -q "/cache"; then pass "$t: volumes"
                else fail "$t: volumes" "got: $v"; fi
                v=$(echo "$ins" | jq -r '.[0].Config.Entrypoint | join(" ")')
                if [ "$v" = "/init" ]; then pass "$t: entrypoint /init"; else fail "$t: entrypoint /init" "got: $v"; fi
                docker rmi containix-test-metadata:test &>/dev/null || true
              }

              # ── test: caddy ──
              test_caddy() {
                local t="caddy"
                log "=== $t ==="
                load "$t" "$COPY_CADDY"
                local cid; cid=$(docker run -d --name "cix-caddy-$$" -p 18083:8080 containix-test-caddy:test)
                CONTAINERS+=("$cid")
                if ! wait_http "http://localhost:18083" 30; then
                  fail "$t" "not ready in 30s"; docker logs "$cid" 2>&1 | tail -20; return; fi
                local body; body=$(curl -sf http://localhost:18083/)
                if echo "$body" | grep -q "CADDY_TEST_OK"; then pass "$t: caddy serves response"
                else fail "$t: caddy serves response" "got: $body"; fi
                docker rm -f "$cid" &>/dev/null || true
              }

              # ── test: secrets ──
              test_secrets() {
                local t="secrets"
                log "=== $t ==="
                load "$t" "$COPY_SECRETS"
                local sdir; sdir=$(mktemp -d)
                echo -n "s3cret_value_123" > "$sdir/test-secret"
                local cid; cid=$(docker run -d --name "cix-secrets-$$" -p 18084:8080 \
                  -v "$sdir/test-secret:/run/secrets/test-secret:ro" containix-test-secrets:test)
                CONTAINERS+=("$cid")
                if ! wait_http "http://localhost:18084" 30; then
                  fail "$t" "not ready in 30s"; docker logs "$cid" 2>&1 | tail -20; rm -rf "$sdir"; return; fi
                local body; body=$(curl -sf http://localhost:18084/)
                if [ "$body" = "s3cret_value_123" ]; then pass "$t: secret via contenv"
                else fail "$t: secret via contenv" "got: $body"; fi
                docker rm -f "$cid" &>/dev/null || true
                rm -rf "$sdir"
              }

              # ── main ──
              echo ""
              echo -e "''${BOLD}containix integration tests''${RESET}"
              echo -e "''${BOLD}══════════════════════════''${RESET}"
              echo ""
              if ! docker info &>/dev/null; then echo "ERROR: docker daemon not running" >&2; exit 1; fi

              test_nginx_static
              test_reverse_proxy
              test_env_init
              test_metadata
              test_caddy
              test_secrets

              echo ""
              echo -e "''${BOLD}Results''${RESET}"
              echo "───────"
              echo -e "  ''${GREEN}Passed: $PASS''${RESET}"
              [ "$FAIL" -gt 0 ] && echo -e "  ''${RED}Failed: $FAIL''${RESET}"
              [ "$SKIP" -gt 0 ] && echo -e "  ''${YELLOW}Skipped: $SKIP''${RESET}"
              if [ "$FAIL" -gt 0 ]; then
                echo ""
                echo -e "''${RED}Failures:''${RESET}"
                for f in "''${FAILURES[@]}"; do echo "  - $f"; done
                exit 1
              fi
              echo ""
              echo -e "''${GREEN}All tests passed.''${RESET}"
            '';
          };
        in {
          type = "app";
          program = "${testScript}/bin/containix-integration-test";
        };
      };

      # ── Evaluation checks ──────────────────────────────────────────────
      # These verify that the module system evaluates correctly for various
      # configurations. They catch type errors, assertion failures, and
      # option misuse at eval time (no container runtime needed).
      checks = let
        # Helper: evaluate a config and return a trivial derivation if it succeeds.
        checkConfig = name: config:
          let img = mkContainer config;
          in pkgs.runCommand "containix-check-${name}" {} ''
            echo "containix check '${name}' evaluated successfully: ${img.name}"
            touch $out
          '';
      in {
        # Minimal: just an image name, no services.
        eval-minimal = checkConfig "minimal" {
          image.name = "check-minimal";
        };

        # nginx basic.
        eval-nginx = checkConfig "nginx" {
          image.name = "check-nginx";
          services.nginx = {
            enable = true;
            virtualHosts.localhost.locations."/".return = "200 ok";
          };
        };

        # caddy basic.
        eval-caddy = checkConfig "caddy" {
          image.name = "check-caddy";
          services.caddy = {
            enable = true;
            virtualHosts.localhost = {};
          };
        };

        # cron.
        eval-cron = checkConfig "cron" {
          image.name = "check-cron";
          services.cron = {
            enable = true;
            jobs.test = { schedule = "* * * * *"; command = "echo ok"; };
          };
        };

        # openssh.
        eval-openssh = checkConfig "openssh" {
          image.name = "check-openssh";
          services.openssh = {
            enable = true;
            port = 2222;
          };
        };

        # All new features: labels, ports, volumes, healthcheck, initScripts, secrets.
        eval-full = checkConfig "full" {
          image.name = "check-full";
          image.tag = "test";
          image.labels = { "org.opencontainers.image.source" = "test"; };
          image.exposedPorts = [ 8080 ];
          image.volumes = [ "/data" ];
          image.healthcheck = {
            enable = true;
            command = "true";
            interval = "30s";
            timeout = "5s";
            retries = 3;
            startPeriod = "10s";
          };
          environment.FOO = "bar";
          initScripts.setup = "mkdir -p /data";
          secrets.my-secret.envVar = "MY_SECRET";
          services.nginx = {
            enable = true;
            virtualHosts.localhost.locations."/".return = "200 ok";
          };
        };

        # Custom s6 service (no module, raw s6Services).
        eval-custom-service = checkConfig "custom-service" {
          image.name = "check-custom";
          s6Services.myapp = {
            kind = "longrun";
            run = "exec echo hello";
          };
        };
      };
    });
}
