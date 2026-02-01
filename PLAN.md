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

- [ ] 2.1 `services.openssh` -- SSH/SFTP server
- [ ] 2.2 `services.dnsmasq` -- lightweight DNS/DHCP sidecar
- [ ] 2.3 `services.vector` -- log/metrics shipping agent
- [ ] 2.4 `services.haproxy` -- TCP/HTTP load balancer
- [ ] 2.5 `services.prometheus-node-exporter` -- metrics exporter sidecar
- [ ] 2.6 `services.wireguard` -- VPN tunnel
- [ ] 2.7 `services.unbound` -- recursive DNS resolver

## Phase 3: Core Framework Improvements

- [x] 3.1 `image.healthcheck` -- OCI HEALTHCHECK metadata
- [x] 3.2 `image.exposedPorts` -- OCI EXPOSE metadata
- [x] 3.3 `image.volumes` -- declare expected mount points
- [x] 3.4 `initScripts` -- oneshot tasks before services start
- [x] 3.5 Secrets handling -- runtime secrets from mounted files (with contenv integration)
- [ ] 3.6 Multi-layer control -- expose nix2container layer options
- [x] 3.7 `image.labels` -- OCI labels (maintainer, version, source URL)
- [ ] 3.8 Declarative rootfs static files -- /etc/passwd, /bin/sh, /run etc. should be driven by module options instead of ad-hoc shell in mk-s6rc-image.nix
- [ ] 3.9 Non-root user support -- `image.users` option to declare users/groups with home dirs, passwd entries. Currently `image.user` sets the OCI User but there's no passwd entry or home dir for non-root UIDs.
- [ ] 3.10 Graceful shutdown -- per-service stop timeout, stop signal config. s6-overlay handles SIGTERM but there's no way to configure shutdown behaviour per service.
- [ ] 3.11 Logging strategy -- design how logging works end-to-end. Questions to answer:
  - s6 captures stdout/stderr per service -- should we expose s6-log options (rotation, max size)?
  - Should there be a per-service `logging = "stdout" | "file" | "none"` option?
  - How does this interact with log shippers like vector/alloy?
  - Some services (nginx) want to log to files by default -- should we redirect those to stdout?
  - Container best practice is stdout-only, but some users want persistent logs in a volume.
  - Consider: `s6Services.<name>.logging.enable`, `s6Services.<name>.logging.maxSize`, `s6Services.<name>.logging.rotate`

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

## Summary of What's Done

Core framework is now **actually tested and working**:
- OCI metadata: labels, exposedPorts, volumes, healthcheck
- Runtime secrets with contenv integration (Docker/K8s compatible)
- Init scripts for pre-service setup
- NixOS-style assertions and warnings
- Integration tests: `nix run .#integration-test` (13 passing assertions)
- Eval checks: `nix flake check` (7 configs)
- GitHub Actions CI with eval + integration test jobs
- Flake template for quick start
- Dev shell for contributors

Next priorities:
1. New service modules (openssh, dnsmasq, vector, haproxy, etc.)
2. Option docs generation (auto-generate from module options)
3. Declarative rootfs (3.8)
