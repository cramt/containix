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

## Phase 4: Testing and CI

- [x] 4.1 `nix flake check` -- checks output evaluating all modules/examples
- [x] 4.2 GitHub Actions CI -- `.github/workflows/ci.yml`
- [ ] 4.3 Integration tests -- build + run images, assert services respond
- [x] 4.4 Module assertions -- fail early with clear error messages (assertions + warnings)

## Phase 5: Developer Experience

- [x] 5.1 Flake template -- `nix flake init -t github:cramt/containix`
- [ ] 5.2 Proper README -- quick start, API reference, comparison to alternatives
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
- **Phase 5 PARTIAL**: flake template, devShells. Remaining: proper README (5.2), option docs generation (5.3)

## Summary of What's Done

Core framework is now production-ready:
- OCI metadata: labels, exposedPorts, volumes, healthcheck
- Runtime secrets with contenv integration (Docker/K8s compatible)
- Init scripts for pre-service setup
- NixOS-style assertions and warnings
- Automated testing via `nix flake check` + GitHub Actions CI
- Flake template for quick start
- Dev shell for contributors

Next priorities:
1. Proper README with examples and API docs
2. New service modules (openssh, dnsmasq, vector, haproxy, etc.)
3. Integration tests (build + run containers in CI)
