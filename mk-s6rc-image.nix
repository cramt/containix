{ pkgs
, nix2containerPkgs
, sources  # npins sources attrset (import ./npins)
, lib ? pkgs.lib
}:

let
  s6ArchPinFor = system:
    if system == "x86_64-linux" then "s6-overlay-x86_64"
    else if system == "aarch64-linux" then "s6-overlay-aarch64"
    else throw "mkS6RcImage: unsupported system ${system}";

  mkEnvList = env:
    if builtins.isList env
    then env
    else lib.mapAttrsToList (k: v: "${k}=${toString v}") env;

  # ── Pure-Nix s6-rc service tree builder ──────────────────────────────
  # Produces a derivation containing the full /etc/s6-overlay/s6-rc.d tree.
  # No shell cat/echo/heredoc -- every file is a pkgs.writeText or
  # pkgs.writeScript, assembled via runCommand with only cp/mkdir/chmod.
  mkS6RcTreeDrv = services:
    let
      # For each service, produce an attrset of { path = derivation } pairs
      mkServiceFiles = name: spec:
        let
          kind = spec.kind or "longrun";
          depsText = lib.concatStringsSep "\n" (spec.after or []);
          base = "etc/s6-overlay/s6-rc.d/${name}";
        in
          # Common files for all service types
          [
            { path = "${base}/type";
              src = pkgs.writeText "${name}-type" kind; }
            { path = "${base}/dependencies";
              src = pkgs.writeText "${name}-deps" depsText; }
          ]
          # Longrun: run script + optional stop signal/timeout + optional logging
          ++ lib.optionals (kind == "longrun") (
            [
              { path = "${base}/run";
                src = pkgs.writeScript "${name}-run" ''
                  #!/command/with-contenv sh
                  set -eu
                  ${spec.run}
                '';
              }
            ]
            ++ lib.optional (spec ? stopSignal && spec.stopSignal != null)
              { path = "${base}/down-signal";
                src = pkgs.writeText "${name}-down-signal" spec.stopSignal; }
            ++ lib.optional (spec ? stopTimeout && spec.stopTimeout != null)
              { path = "${base}/timeout-kill";
                src = pkgs.writeText "${name}-timeout-kill" (toString spec.stopTimeout); }
            ++ lib.optionals (spec ? logging && spec.logging.enable or false) [
              { path = "${base}/log/run";
                src = pkgs.writeScript "${name}-log-run" ''
                  #!/command/execlineb -P
                  mkdir -p ${spec.logging.directory}
                  s6-log -b -- n${toString spec.logging.maxFiles} s${toString spec.logging.maxSize} ${spec.logging.directory}
                '';
              }
            ]
          )
          # Oneshot: up script (wrapper + .sh) + optional down
          ++ lib.optionals (kind == "oneshot") (
            [
              { path = "${base}/up.sh";
                src = pkgs.writeScript "${name}-up-sh" ''
                  #!/bin/sh
                  set -eu
                  ${spec.up}
                '';
              }
              { path = "${base}/up";
                src = pkgs.writeScript "${name}-up" ''
                  /command/with-contenv /bin/sh /etc/s6-overlay/s6-rc.d/${name}/up.sh
                '';
              }
            ]
            ++ lib.optionals (spec ? down && spec.down != null) [
              { path = "${base}/down.sh";
                src = pkgs.writeScript "${name}-down-sh" ''
                  #!/bin/sh
                  set -eu
                  ${spec.down}
                '';
              }
              { path = "${base}/down";
                src = pkgs.writeScript "${name}-down" ''
                  /command/with-contenv /bin/sh /etc/s6-overlay/s6-rc.d/${name}/down.sh
                '';
              }
            ]
          );

      # User bundle: empty marker files that tell s6-overlay which services to start
      bundleFiles = map (name:
        { path = "etc/s6-overlay/s6-rc.d/user/contents.d/${name}";
          src = pkgs.writeText "user-bundle-${name}" ""; }
      ) (builtins.attrNames services);

      allFiles =
        (lib.concatLists (lib.mapAttrsToList mkServiceFiles services))
        ++ bundleFiles;

    in pkgs.runCommand "s6-rc-tree" {} (''
      set -eu
      mkdir -p "$out"
    '' + lib.concatMapStringsSep "\n" (f: ''
      mkdir -p "$out/$(dirname "${f.path}")"
      cp "${f.src}" "$out/${f.path}"
      chmod +x "$out/${f.path}" 2>/dev/null || true
    '') allFiles);

  # ── Pure-Nix /etc/passwd and /etc/group ──────────────────────────────
  mkPasswd = users: pkgs.writeText "passwd"
    (lib.concatStringsSep "\n" (lib.mapAttrsToList (name: u:
      "${name}:x:${toString u.uid}:${toString u.gid}:${u.description}:${u.home}:${u.shell}"
    ) users));

  mkGroup = groups: pkgs.writeText "group"
    (lib.concatStringsSep "\n" (lib.mapAttrsToList (name: g:
      "${name}:x:${toString g.gid}:"
    ) groups));

  # ── Pure-Nix /usr/local/bin symlink tree ─────────────────────────────
  mkUsrLocalBin = extraPaths:
    pkgs.runCommand "usr-local-bin" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
      mkdir -p $out/usr/local/bin
      ${lib.concatStringsSep "\n" (map (p: ''
        if [ -d "${p}/bin" ]; then
          for exe in ${p}/bin/*; do
            ln -sf "$exe" "$out/usr/local/bin/$(basename "$exe")"
          done
        fi
      '') extraPaths)}
    '';

  # Convert a Go-style duration string (e.g. "30s", "1m", "500ms") to nanoseconds.
  # OCI Healthcheck uses nanosecond integers.
  parseDuration = s:
    let
      m = builtins.match "([0-9]+)(ms|s|m|h)" s;
      value = if m != null then lib.toInt (builtins.elemAt m 0) else throw "parseDuration: invalid duration '${s}'";
      unit = if m != null then builtins.elemAt m 1 else "";
      multiplier =
        if unit == "ms" then 1000000
        else if unit == "s" then 1000000000
        else if unit == "m" then 60000000000
        else if unit == "h" then 3600000000000
        else throw "parseDuration: unknown unit '${unit}'";
    in value * multiplier;

in

# mkS6RcImage :: { ... } -> image
{ name
, tag ? null
, user ? "1000:1000"
, env ? {}
, copyToRoot ? []
, extraPaths ? []            # packages whose /bin/* should appear in /usr/local/bin
, extraFiles ? []            # [{ source = ./file; target = "etc/foo"; }]
, services ? {}              # s6-rc services graph
, labels ? {}                # OCI labels
, exposedPorts ? []          # list of port ints -> OCI ExposedPorts
, volumes ? []               # list of path strings -> OCI Volumes
, healthcheck ? null         # { command, interval, timeout, retries, startPeriod } or null
, users ? {}
, groups ? {}
, shell ? pkgs.bash
, basePackages ? [ pkgs.coreutils ]
}:

let
  system = pkgs.stdenv.hostPlatform.system;

  # Fetch raw tarballs using URL+hash from npins sources.json.
  s6NoarchPin = sources."s6-overlay-noarch";
  s6ArchPin = sources.${s6ArchPinFor system};

  s6NoarchTar = pkgs.fetchurl {
    url = s6NoarchPin.url;
    hash = s6NoarchPin.hash;
  };

  s6ArchTar = pkgs.fetchurl {
    url = s6ArchPin.url;
    hash = s6ArchPin.hash;
  };

  # ── Declarative rootfs pieces ────────────────────────────────────────
  # Each piece is a self-contained derivation.  The final rootfs just
  # overlays them together.

  # 1. s6-overlay binaries (only thing that truly needs tar extraction)
  s6Overlay = pkgs.runCommand "s6-overlay" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.xz ];
  } ''
    mkdir -p "$out"
    tar -C "$out" --no-same-permissions -Jxf ${s6NoarchTar}
    tar -C "$out" --no-same-permissions -Jxf ${s6ArchTar}
  '';

  # 2. s6-rc service tree (pure Nix -- no shell generation)
  s6RcTree = mkS6RcTreeDrv services;

  # 3. /etc/passwd and /etc/group
  passwdFile = mkPasswd users;
  groupFile  = mkGroup groups;

  # 4. /usr/local/bin symlinks for user packages
  usrLocal = mkUsrLocalBin extraPaths;

  # 5. Compose the rootfs: overlay all pieces + create structural dirs/symlinks.
  #    This is the only runCommand left, and it does only filesystem assembly
  #    (cp, ln, mkdir) -- no content generation.
  rootfs = pkgs.runCommand "s6-rootfs" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    set -eu
    mkdir -p "$out"

    # Overlay s6-overlay binaries.  --preserve=mode keeps execute bits on
    # /init, /command/*, /package/** but --no-preserve=ownership ensures
    # the builder owns the files so chmod works in the Nix sandbox.
    cp -r --preserve=mode,timestamps --no-preserve=ownership ${s6Overlay}/. "$out/"
    chmod -R u+w "$out"

    # Overlay s6-rc service tree (preserves +x on run/up scripts).
    # Note: cp --preserve=mode will reset $out/etc/ permissions from the
    # source tree, so we must chmod again after this copy.
    cp -r --preserve=mode,timestamps --no-preserve=ownership ${s6RcTree}/. "$out/"
    chmod -R u+w "$out"

    # /etc/passwd and /etc/group
    cp ${passwdFile} "$out/etc/passwd"
    cp ${groupFile}  "$out/etc/group"

    # Home directories for declared users
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: u:
      lib.optionalString (u.home != "/nonexistent" && u.home != "/usr/sbin/nologin") ''
        mkdir -p "$out${u.home}"
      ''
    ) users)}

    # Structural directories
    mkdir -p "$out/tmp" "$out/run" "$out/var" "$out/bin" "$out/usr/bin"
    ln -sf /run "$out/var/run"

    # Shell: /bin/sh, /bin/bash
    ln -sf ${shell}/bin/bash "$out/bin/sh"
    ln -sf ${shell}/bin/bash "$out/bin/bash"

    # Base packages -> /usr/bin/*
    ${lib.concatStringsSep "\n" (map (pkg: ''
      for exe in ${pkg}/bin/*; do
        ln -sf "$exe" "$out/usr/bin/$(basename "$exe")"
      done
    '') basePackages)}
    ln -sf ${builtins.head basePackages}/bin/env "$out/bin/env"

    # Extra files from modules (config files, static assets, etc.)
    ${lib.concatStringsSep "\n" (map (f: ''
      mkdir -p "$out/$(dirname "${f.target}")"
      cp --no-preserve=mode "${f.source}" "$out/${f.target}"
    '') extraFiles)}
  '';

  envList = mkEnvList env;

  # OCI ExposedPorts is a map of "port/tcp" -> {}
  exposedPortsConfig =
    if exposedPorts == [] then {}
    else lib.listToAttrs (map (p: lib.nameValuePair "${toString p}/tcp" {}) exposedPorts);

  # OCI Volumes is a map of "/path" -> {}
  volumesConfig =
    if volumes == [] then {}
    else lib.listToAttrs (map (v: lib.nameValuePair v {}) volumes);

  healthcheckConfig =
    if healthcheck == null then {}
    else {
      Healthcheck = {
        Test = [ "CMD-SHELL" healthcheck.command ];
        Interval = parseDuration healthcheck.interval;
        Timeout = parseDuration healthcheck.timeout;
        Retries = healthcheck.retries;
        StartPeriod = parseDuration healthcheck.startPeriod;
      };
    };

in
nix2containerPkgs.nix2container.buildImage {
  inherit name tag;

  copyToRoot = [ rootfs usrLocal ] ++ copyToRoot;

  config = {
    Entrypoint = [ "/init" ];
    Env = envList ++ [ "PATH=/usr/local/bin:/command:/usr/bin:/bin" ];
    User = user;
  }
  // (if labels != {} then { Labels = labels; } else {})
  // (if exposedPorts != [] then { ExposedPorts = exposedPortsConfig; } else {})
  // (if volumes != [] then { Volumes = volumesConfig; } else {})
  // healthcheckConfig;
}
