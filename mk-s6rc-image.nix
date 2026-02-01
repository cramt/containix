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

  # Write an executable script into a rootfs build output.
  writeExe = { root, path, text }:
    ''
      mkdir -p "$(dirname "${root}/${path}")"
      cat > "${root}/${path}" << 'ENDOFSCRIPT'
${text}
ENDOFSCRIPT
      chmod +x "${root}/${path}"
    '';

  # s6-rc source layout generator
  # service spec:
  # {
  #   kind = "longrun" | "oneshot";
  #   run  = "...";      # for longrun
  #   up   = "...";      # for oneshot
  #   down = "...";      # optional oneshot down
  #   after = [ "svcA" "svcB" ];  # dependencies
  # }
  mkS6RcTree = { root, services }:
    let
      mkDeps = deps: lib.concatStringsSep "\n" deps;
      mkOne = name: spec:
        let
          depsText = mkDeps (spec.after or []);
          kind = spec.kind or "longrun";
        in
          if kind == "longrun" then ''
            mkdir -p "${root}/etc/s6-overlay/s6-rc.d/${name}"
            echo "longrun" > "${root}/etc/s6-overlay/s6-rc.d/${name}/type"
            cat > "${root}/etc/s6-overlay/s6-rc.d/${name}/dependencies" << 'ENDDEPS'
${depsText}
ENDDEPS
            ${writeExe {
              root = root;
              path = "etc/s6-overlay/s6-rc.d/${name}/run";
              text = ''
                #!/command/with-contenv sh
                set -eu
                ${spec.run}
              '';
            }}
          ''
          else if kind == "oneshot" then ''
            mkdir -p "${root}/etc/s6-overlay/s6-rc.d/${name}"
            echo "oneshot" > "${root}/etc/s6-overlay/s6-rc.d/${name}/type"
            cat > "${root}/etc/s6-overlay/s6-rc.d/${name}/dependencies" << 'ENDDEPS'
${depsText}
ENDDEPS
            # Oneshot `up` scripts are executed by execlineb, not as
            # regular shell scripts.  We write the user script to a
            # separate .sh file and have the `up` file invoke it via
            # with-contenv + sh.
            ${writeExe {
              root = root;
              path = "etc/s6-overlay/s6-rc.d/${name}/up.sh";
              text = ''
                #!/bin/sh
                set -eu
                ${spec.up}
              '';
            }}
            ${writeExe {
              root = root;
              path = "etc/s6-overlay/s6-rc.d/${name}/up";
              text = ''
                /command/with-contenv /bin/sh /etc/s6-overlay/s6-rc.d/${name}/up.sh
              '';
            }}
            ${
              if spec ? down then
                writeExe {
                  root = root;
                  path = "etc/s6-overlay/s6-rc.d/${name}/down.sh";
                  text = ''
                    #!/bin/sh
                    set -eu
                    ${spec.down}
                  '';
                }
                + writeExe {
                  root = root;
                  path = "etc/s6-overlay/s6-rc.d/${name}/down";
                  text = ''
                    /command/with-contenv /bin/sh /etc/s6-overlay/s6-rc.d/${name}/down.sh
                  '';
                }
              else ""
            }
          ''
          else throw "mkS6RcImage: service ${name} has unknown kind ${kind}";
      # Register each service in the s6-overlay "user" bundle so it
      # actually gets started.  s6-overlay looks for empty files in
      # /etc/s6-overlay/s6-rc.d/user/contents.d/<service-name>.
      mkUserBundle = names: ''
        mkdir -p "${root}/etc/s6-overlay/s6-rc.d/user/contents.d"
        ${lib.concatMapStringsSep "\n" (n: ''
          touch "${root}/etc/s6-overlay/s6-rc.d/user/contents.d/${n}"
        '') names}
      '';
    in
      lib.concatStringsSep "\n" (lib.mapAttrsToList mkOne services)
      + "\n"
      + mkUserBundle (builtins.attrNames services);

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
  # npins tracks these as "Tarball" type but we need the raw .tar.xz,
  # not the unpacked store path that npins' default.nix would give us.
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

  rootfs = pkgs.runCommand "s6-rootfs" { nativeBuildInputs = [ pkgs.gnutar pkgs.xz pkgs.coreutils ]; } ''
    set -eu
    mkdir -p "$out"

    # Install s6-overlay into rootfs: provides /init and /command/*
    # Use --no-same-permissions to avoid setuid failures in the Nix sandbox.
    # The setuid bit on s6-overlay-suexec is not needed for container use
    # (containers run as root or use user namespaces).
    tar -C "$out" --no-same-permissions -Jxf ${s6NoarchTar}
    tar -C "$out" --no-same-permissions -Jxf ${s6ArchTar}

    # Minimal /etc/passwd and /etc/group so the container runtime can
    # resolve user names. Without these, Docker refuses to start the
    # container when User is set to a name like "root".
    mkdir -p "$out/etc"
    cat > "$out/etc/passwd" <<'PASSWD'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
PASSWD
    cat > "$out/etc/group" <<'GROUP'
root:x:0:
nogroup:x:65534:
nobody:x:65534:
GROUP
    mkdir -p "$out/root" "$out/tmp"

    # s6-overlay expects /run and /var/run (symlinked).
    mkdir -p "$out/run"
    mkdir -p "$out/var"
    ln -sf /run "$out/var/run"

    # s6-overlay's /init is a shell script that requires /bin/sh.
    # Provide bash and coreutils in /bin and /usr/bin so that s6-overlay
    # init scripts and service run scripts have a working environment.
    mkdir -p "$out/bin" "$out/usr/bin"
    ln -sf ${pkgs.bash}/bin/bash "$out/bin/sh"
    ln -sf ${pkgs.bash}/bin/bash "$out/bin/bash"
    for exe in ${pkgs.coreutils}/bin/*; do
      ln -sf "$exe" "$out/usr/bin/$(basename "$exe")"
    done
    ln -sf ${pkgs.coreutils}/bin/env "$out/bin/env"

    # s6-overlay will start s6-rc services from /etc/s6-overlay/s6-rc.d at init
    mkdir -p "$out/etc/s6-overlay/s6-rc.d"

    # Drop extra files/configs
    ${lib.concatStringsSep "\n" (map (f: ''
      mkdir -p "$out/$(dirname "${f.target}")"
      cp -a "${f.source}" "$out/${f.target}"
    '') extraFiles)}

    # Generate s6-rc service graph
    ${mkS6RcTree { root = "$out"; inherit services; }}
  '';

  usrLocal = pkgs.runCommand "usr-local-bin" { nativeBuildInputs = [ pkgs.coreutils ]; } ''
    mkdir -p $out/usr/local/bin
    ${lib.concatStringsSep "\n" (map (p: ''
      if [ -d "${p}/bin" ]; then
        for exe in ${p}/bin/*; do
          ln -sf "$exe" "$out/usr/local/bin/$(basename "$exe")"
        done
      fi
    '') extraPaths)}
  '';

  envList = mkEnvList env;

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
