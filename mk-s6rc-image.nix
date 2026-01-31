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
      cat > "${root}/${path}" <<'EOF'
      ${text}
      EOF
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
            cat > "${root}/etc/s6-overlay/s6-rc.d/${name}/dependencies" <<'EOF'
            ${depsText}
            EOF
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
            cat > "${root}/etc/s6-overlay/s6-rc.d/${name}/dependencies" <<'EOF'
            ${depsText}
            EOF
            ${writeExe {
              root = root;
              path = "etc/s6-overlay/s6-rc.d/${name}/up";
              text = ''
                #!/command/with-contenv sh
                set -eu
                ${spec.up}
              '';
            }}
            ${
              if spec ? down then writeExe {
                root = root;
                path = "etc/s6-overlay/s6-rc.d/${name}/down";
                text = ''
                  #!/command/with-contenv sh
                  set -eu
                  ${spec.down}
                '';
              } else ""
            }
          ''
          else throw "mkS6RcImage: service ${name} has unknown kind ${kind}";
    in
      lib.concatStringsSep "\n" (lib.mapAttrsToList mkOne services);

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

    # Install s6-overlay into rootfs: provides /init and /command/* [1](https://discourse.nixos.org/t/how-to-run-a-dockertools-built-image-with-virtualisation-oci-containers-containers/62410)
    tar -C "$out" -Jxpf ${s6NoarchTar}
    tar -C "$out" -Jxpf ${s6ArchTar}

    # s6-overlay will start s6-rc services from /etc/s6-overlay/s6-rc.d at init [1](https://discourse.nixos.org/t/how-to-run-a-dockertools-built-image-with-virtualisation-oci-containers-containers/62410)
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

in
nix2containerPkgs.nix2container.buildImage {
  inherit name tag;

  copyToRoot = [ rootfs usrLocal ] ++ copyToRoot;

  config = {
    Entrypoint = [ "/init" ];  # s6-overlay PID 1 [1](https://discourse.nixos.org/t/how-to-run-a-dockertools-built-image-with-virtualisation-oci-containers-containers/62410)
    Env = envList ++ [ "PATH=/usr/local/bin:/command:/usr/bin:/bin" ];
    User = user;               # Scaleway non-root [2](https://minin.tech/posts/docker-containers-priviliged-unpriviliged-rootless/)[3](https://gist.github.com/pinkeen/bba0a6790fec96d6c8de84bd824ad933)
  };
}
