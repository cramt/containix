# Containix Roadmap & Progress Tracker

This file tracks the plan for making containix production-useful.
It serves as the issue tracker for AI-assisted development sessions.

---

## Phase 1: Fix What's Broken

- [x] 1.1 Remove postgresql/redis references from AGENT.md
- [x] 1.2 Remove postgresql/redis references from examples (monitored-app)
- [x] 1.3 Validate all examples evaluate with `nix eval`

## Phase 2: Service Modules That Make Sense in Containers

Stateless services, proxies, sidecars, agents -- things that belong in containers.

- [x] 2.1 `services.openssh` -- SSH/SFTP server (+ integration test)
- [x] 2.2 `services.dnsmasq` -- lightweight DNS/DHCP sidecar
- [x] 2.3 `services.vector` -- log/metrics shipping agent
- [x] 2.4 `services.haproxy` -- TCP/HTTP load balancer
- [x] 2.5 `services.prometheus-node-exporter` -- metrics exporter sidecar
- [x] 2.6 `services.wireguard` -- VPN tunnel
- [x] 2.7 `services.unbound` -- recursive DNS resolver

## Phase 3: Core Framework Improvements

- [x] 3.1 `image.healthcheck` -- OCI HEALTHCHECK metadata
- [x] 3.2 `image.exposedPorts` -- OCI EXPOSE metadata
- [x] 3.3 `image.volumes` -- declare expected mount points
- [x] 3.4 `initScripts` -- oneshot tasks before services start
- [x] 3.5 Secrets handling -- runtime secrets from mounted files (with contenv integration)
- [ ] 3.6 Multi-layer control -- expose nix2container layer options
- [x] 3.7 `image.labels` -- OCI labels (maintainer, version, source URL)
- [x] 3.8 Declarative rootfs -- mk-s6rc-image.nix rewritten from imperative shell (cat/echo/heredoc) to pure Nix derivations. s6-rc tree, /etc/passwd, /etc/group, /usr/local/bin symlinks all built as separate derivations and assembled via a single rootfs runCommand that only does cp/ln/mkdir.
- [x] 3.9 Non-root user support -- `image.users`/`image.groups` options wired through to mk-s6rc-image.nix. Generates /etc/passwd and /etc/group from declared users. Home dirs auto-created. Also wired `image.shell` and `image.basePackages` through.
- [x] 3.10 Graceful shutdown -- `s6Services.<name>.stopSignal` and `s6Services.<name>.stopTimeout` options. Generates s6 `down-signal` and `timeout-kill` files. nginx defaults to SIGQUIT/10s, haproxy to SIGUSR1/30s.
- [x] 3.11 Logging strategy -- `s6Services.<name>.logging.{enable, directory, maxSize, maxFiles}`. Default is stdout (container best practice). When enabled, pipes through s6-log with rotation. Design decisions:
  - Default: stdout-only (container best practice, works with docker logs / kubectl logs)
  - Opt-in: per-service s6-log with configurable rotation (for users who want persistent logs in volumes)
  - Log shippers (vector/alloy) can consume either stdout or log files

## Phase 4: Testing and CI

- [x] 4.1 `nix flake check` -- checks output evaluating all modules/examples
- [x] 4.2 GitHub Actions CI -- `.github/workflows/ci.yml`
- [x] 4.3 Integration tests -- build + run images, assert services respond
- [x] 4.4 Module assertions -- fail early with clear error messages (assertions + warnings)

## Phase 5: Developer Experience

- [x] 5.1 Flake template -- `nix flake init -t github:cramt/containix`
- [x] 5.2 Proper README -- quick start, API reference, comparison to alternatives
- [ ] 5.3 Option docs generation -- auto-generate from module options
- [x] 5.4 `devShells` -- dev shell with npins and tools

## Phase 6: Ecosystem Integration

- [ ] 6.1 Docker Compose generation -- `lib.mkComposeFile`
- [ ] 6.2 Kubernetes manifest generation
- [ ] 6.3 Binary cache docs -- document Cachix workflow

---

## Session Log

### Session 1 (2026-02-01)
- Created this plan file
- Updated AGENT.md to reference this file
- **Phase 1 COMPLETE**: removed postgresql/redis from AGENT.md and monitored-app example, validated all 3 examples evaluate
- **Phase 3 MOSTLY COMPLETE**: implemented image.labels, image.exposedPorts, image.volumes, image.healthcheck, initScripts, secrets (with contenv integration). Remaining: multi-layer control (3.6) - low priority
- **Phase 4 MOSTLY COMPLETE**: nix flake check with 6 eval checks, GitHub Actions CI, NixOS-style assertions+warnings. Remaining: integration tests (4.3) - would require podman/docker in CI
- **Phase 5 MOSTLY COMPLETE**: flake template, devShells, comprehensive README with quick start, API reference, examples, and comparison to alternatives. Remaining: option docs generation (5.3)

### Session 2 (2026-02-01)
- **Phase 4 COMPLETE**: Integration tests that actually build, load, run, and probe containers
  - 6 test images: nginx-static, reverse-proxy, env+initScripts, OCI metadata, caddy, secrets
  - 13 assertions covering HTTP responses, env vars, init scripts, labels, ports, volumes, entrypoint, secrets via contenv
  - Test runner is a Nix package (`nix run .#integration-test`) -- all deps (curl, jq, docker) provided by Nix
  - CI updated: eval checks + integration tests run in parallel jobs
- **Critical framework fixes found by integration tests**:
  - Added /etc/passwd, /etc/group, /bin/sh, /usr/bin/coreutils, /run, /var/run to rootfs (containers were non-functional without these)
  - Fixed s6-rc user bundle registration (services weren't starting)
  - Fixed oneshot script execution (execline vs shell semantics)
  - Fixed heredoc indentation in generated s6-rc scripts
  - Updated s6-overlay tarball hashes
- Added `services.openssh` module (eval-tested, not yet integration-tested)
- Added 3.8 to plan: declarative rootfs static files

### Session 3 (2026-02-02)
- **Phase 2 COMPLETE**: All 7 service modules implemented and eval-tested
  - `services.openssh` -- SSH/SFTP server with privsep user, host key generation, pubkey/password auth
  - `services.dnsmasq` -- DNS/DHCP sidecar with structured config (servers, addresses, DHCP ranges)
  - `services.vector` -- log/metrics agent with sources/transforms/sinks config
  - `services.haproxy` -- TCP/HTTP load balancer with frontends/backends/stats/ACLs
  - `services.prometheus-node-exporter` -- metrics exporter with collector enable/disable
  - `services.wireguard` -- VPN tunnel with peers, key management, capability warnings
  - `services.unbound` -- recursive DNS resolver with DNSSEC, forwarding, caching
- **openssh integration-tested**: 3 assertions (SSH connect, remote exec, SFTP subsystem)
  - Fixed: sshd privsep user (`image.users.sshd`), `/var/empty` chroot dir
  - Fixed: authorized_keys permissions (staging mount + initScript copy)
  - Fixed: SSH test never prompts (BatchMode=yes, IdentitiesOnly=yes, unset SSH_AUTH_SOCK)
- **Framework improvements**:
  - 3.9 Non-root user support: `image.users`/`image.groups` wired through to mk-s6rc-image.nix. Default users (root, nobody) set via config block so they merge with module-defined users. Home dirs auto-created.
  - 3.10 Graceful shutdown: `s6Services.<name>.stopSignal` and `stopTimeout`. nginx defaults to SIGQUIT/10s, haproxy to SIGUSR1/30s.
  - 3.11 Logging: `s6Services.<name>.logging.{enable, directory, maxSize, maxFiles}`. Default stdout (container best practice), opt-in s6-log with rotation.
  - Wired `image.shell` and `image.basePackages` through mkContainer -> mkS6RcImage (no longer hardcoded).
- **Test results**: 13 eval checks pass, 16 integration test assertions pass (7 test images)
- **Critical bug fixed**: `image.users` default attrset was being replaced (not merged) when service modules added users. Moved defaults to `config` block with `lib.mkDefault`.

### Session 4 (2026-02-02)
- **3.8 Declarative rootfs COMPLETE**: `mk-s6rc-image.nix` fully rewritten
  - `mkS6RcTreeDrv`: Pure Nix s6-rc service tree builder. Each file (type, deps, run, up, down-signal, timeout-kill, log/run) is a `pkgs.writeText` or `pkgs.writeScript`. Assembled via `runCommand` with only cp/mkdir/chmod.
  - `mkPasswd`/`mkGroup`: Pure `writeText` derivations for /etc/passwd and /etc/group.
  - `mkUsrLocalBin`: Derivation that creates /usr/local/bin symlinks for user packages.
  - `rootfs`: Single `runCommand` that overlays all pieces (s6-overlay tarballs, s6-rc tree, passwd/group, structural dirs, shell symlinks, base packages, extra files). No content generation -- only filesystem assembly.
  - **Permission bug fixed**: s6-overlay tarballs create dirs with `dr-xr-xr-x` (555). Solution: `cp -r --preserve=mode,timestamps --no-preserve=ownership` to keep execute bits while ensuring builder owns files, then `chmod -R u+w "$out"` after each overlay step. The second `chmod` is critical because `cp --preserve=mode` resets directory permissions from the source tree.
- **AGENT.md updated**: Added testing rules section requiring `nix flake check` and `nix run .#integration-test` before considering work done.
- **All tests pass**: 13 eval checks, 16 integration test assertions (7 test images)

### Session 5 (2026-02-02)
- **Declarative files option**: Rewrote `files` from a list of `{ source, target }` to a NixOS `environment.etc`-style attrset keyed by target path.
  - `files."etc/foo".text = "..."` -- inline content, auto-creates `pkgs.writeText` derivation
  - `files."etc/foo".source = ./file` -- path or derivation
  - `files."etc/foo".mode = "0640"` -- file permissions (default `"0444"`)
  - `files."etc/foo".enable = false` -- conditionally exclude files
  - `target` defaults to the attribute name (like `environment.etc`)
  - Uses `lib.mkDerivedConfig` for `text` -> `source` derivation (same pattern as NixOS)
- **Updated all consumers**: 9 service modules, 2 examples, 3 test images, flake.nix bridge, README, AGENT.md
- **All tests pass**: 13 eval checks, 16 integration test assertions (7 test images)

## Summary of What's Done

Core framework is **tested and working** with a full service module ecosystem:
- **12 service modules**: nginx, caddy, cron, grafana-alloy, tailscale-ssh, openssh, dnsmasq, vector, haproxy, prometheus-node-exporter, wireguard, unbound
- OCI metadata: labels, exposedPorts, volumes, healthcheck
- Runtime secrets with contenv integration (Docker/K8s compatible)
- Init scripts for pre-service setup
- Declarative users/groups with auto-generated /etc/passwd, /etc/group
- Declarative rootfs: pure Nix derivations for s6-rc tree, passwd/group, symlinks
- Declarative files: NixOS `environment.etc`-style `files.*` with `text`/`source`/`mode`/`enable`
- Graceful shutdown: per-service stop signal and timeout
- Per-service logging: opt-in s6-log with rotation
- NixOS-style assertions and warnings
- Integration tests: `nix run .#integration-test` (16 passing assertions, 7 test images)
- Eval checks: `nix flake check` (13 configs)
- GitHub Actions CI with eval + integration test jobs
- Flake template for quick start
- Dev shell for contributors

Next priorities:
1. Option docs generation (auto-generate from module options) (5.3)
2. Multi-layer control (3.6) -- expose nix2container layer options
3. Ecosystem integration: Docker Compose generation, K8s manifests (6.x)
