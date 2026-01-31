# services.tailscale-ssh – Tailscale VPN + Dropbear SSH as s6-rc services.
#
# Three s6-rc units:
#   tailscaled  (longrun)  – the tailscale daemon
#   tailscale-up (oneshot) – joins the tailnet, enables SSH
#   dropbear    (longrun)  – SSH server, depends on tailscale-up
#
# A separate oneshot (tailscale-ssh-init) handles all the /etc file setup
# so it runs exactly once rather than on every service restart.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.tailscale-ssh;

  dropbearPkg = cfg.dropbearPackage.overrideAttrs (prev: {
    configureFlags = (prev.configureFlags or []) ++ [ "--disable-shadow" ];
  });

  shellBin = lib.getExe cfg.shell;

  # Script that dumps the container's environment into a sourceable file
  # so SSH sessions inherit all env vars (DATABASE_URL, APP_ENV, etc.).
  # `export -p` outputs lines like `export FOO='bar'` which are directly sourceable.
  envSetup = pkgs.writeScript "generate-env" ''
    #!/command/with-contenv sh
    set -eu
    export -p > /.env.sh
  '';
in
{
  options.services.tailscale-ssh = {
    enable = lib.mkEnableOption "Tailscale VPN with SSH access via Dropbear";

    tailscalePackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tailscale;
      description = "The tailscale package to use.";
    };

    dropbearPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dropbear;
      description = "The dropbear package to use (will be built with --disable-shadow).";
    };

    loginServer = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Tailscale coordination/login server URL.
        Leave empty for the default Tailscale control plane.
        Set to a Headscale URL for self-hosted.
      '';
    };

    advertiseExitNode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to advertise this node as an exit node.";
    };

    sshPort = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = "Port dropbear listens on for SSH.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/tailscale_state_dir";
      description = "Directory for tailscaled persistent state.";
    };

    shell = lib.mkOption {
      type = lib.types.package;
      default = pkgs.bash;
      description = "Shell to use for SSH sessions.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ pkgs.busybox ];
      description = "Extra packages available in the SSH session PATH.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [
      cfg.tailscalePackage
      dropbearPkg
      cfg.shell
      pkgs.shadow
    ] ++ cfg.extraPackages;

    # --- oneshot: filesystem setup (runs once, before anything else) ---
    s6Services.tailscale-ssh-init = {
      kind = "oneshot";
      up = ''
        # /etc skeleton for login
        mkdir -p /etc/dropbear
        echo "${shellBin}" > /etc/shells
        echo "root:x:0:0:root:/:${shellBin}" > /etc/passwd
        echo "root:x:0:" > /etc/group
        touch /etc/shadow
        ${pkgs.shadow}/bin/passwd -d root

        # Tailscale state dir
        mkdir -p ${cfg.stateDir}

        # Dump container env vars so SSH sessions can source them
        ${envSetup}
      '';
    };

    # --- longrun: tailscale daemon ---
    s6Services.tailscaled = {
      kind = "longrun";
      after = [ "tailscale-ssh-init" ];
      run = ''
        exec ${cfg.tailscalePackage}/bin/tailscaled \
          --tun=userspace-networking \
          --statedir ${cfg.stateDir}
      '';
    };

    # --- oneshot: join tailnet + enable SSH ---
    s6Services.tailscale-up = {
      kind = "oneshot";
      after = [ "tailscaled" ];
      up = ''
        # Wait for tailscaled to be ready (with timeout)
        n=0
        while ! ${cfg.tailscalePackage}/bin/tailscale status >/dev/null 2>&1; do
          n=$((n + 1))
          if [ "$n" -ge 150 ]; then
            echo "tailscale-up: tailscaled not ready after 30s, giving up" >&2
            exit 1
          fi
          sleep 0.2
        done

        ${cfg.tailscalePackage}/bin/tailscale up \
          --auth-key="$TAILSCALE_AUTHKEY" \
          ${lib.optionalString (cfg.loginServer != "") "--login-server ${cfg.loginServer}"}
        ${cfg.tailscalePackage}/bin/tailscale set --ssh
        ${lib.optionalString cfg.advertiseExitNode
          "${cfg.tailscalePackage}/bin/tailscale set --advertise-exit-node"}
      '';
    };

    # --- longrun: dropbear SSH server ---
    s6Services.dropbear = {
      kind = "longrun";
      after = [ "tailscale-up" ];
      run = ''
        exec ${dropbearPkg}/bin/dropbear -RFEBe \
          -p ${toString cfg.sshPort} \
          -G root \
          -c "source /.env.sh; exec ${shellBin}"
      '';
    };
  };
}
