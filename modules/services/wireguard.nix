# services.wireguard – WireGuard VPN tunnel.
#
# Sets up a WireGuard interface inside the container. Useful for
# connecting containers to private networks, site-to-site VPNs,
# or mesh networking.
#
# Note: Requires NET_ADMIN and NET_RAW capabilities, and typically
# needs --cap-add=NET_ADMIN --cap-add=NET_RAW --sysctl net.ipv4.conf.all.src_valid_mark=1
# when running the container.
{ lib, pkgs, config, ... }:

let
  cfg = config.services.wireguard;

  peerConfig = peer: ''
    [Peer]
    PublicKey = ${peer.publicKey}
    ${lib.optionalString (peer.presharedKeyFile != null) "PresharedKey = PLACEHOLDER_PSK_${peer.publicKey}"}
    ${lib.optionalString (peer.endpoint != null) "Endpoint = ${peer.endpoint}"}
    AllowedIPs = ${lib.concatStringsSep ", " peer.allowedIPs}
    ${lib.optionalString (peer.persistentKeepalive != null) "PersistentKeepalive = ${toString peer.persistentKeepalive}"}
  '';

  wgConf = pkgs.writeText "wg0.conf" ''
    [Interface]
    ${lib.optionalString (cfg.address != null) "Address = ${cfg.address}"}
    ${lib.optionalString (cfg.listenPort != null) "ListenPort = ${toString cfg.listenPort}"}
    ${lib.optionalString (cfg.dns != null) "DNS = ${cfg.dns}"}
    ${lib.optionalString (cfg.mtu != null) "MTU = ${toString cfg.mtu}"}
    ${lib.optionalString (cfg.table != null) "Table = ${cfg.table}"}
    ${lib.optionalString cfg.postUp != "" "PostUp = ${cfg.postUp}"}
    ${lib.optionalString cfg.postDown != "" "PostDown = ${cfg.postDown}"}

    ${lib.concatMapStringsSep "\n" peerConfig cfg.peers}
  '';

  # Init script that substitutes the private key and any preshared keys
  # from runtime secret files into the config, then brings up the interface.
  initWg = pkgs.writeShellScript "init-wireguard" ''
    set -eu
    mkdir -p /etc/wireguard

    # Start with the template config
    cp ${wgConf} /etc/wireguard/${cfg.interfaceName}.conf
    chmod 600 /etc/wireguard/${cfg.interfaceName}.conf

    # Substitute private key from file
    if [ -f "${cfg.privateKeyFile}" ]; then
      PRIVKEY=$(cat "${cfg.privateKeyFile}")
      sed -i "1a PrivateKey = $PRIVKEY" /etc/wireguard/${cfg.interfaceName}.conf
    else
      echo "ERROR: WireGuard private key file '${cfg.privateKeyFile}' not found" >&2
      exit 1
    fi

    ${lib.concatMapStringsSep "\n" (peer:
      lib.optionalString (peer.presharedKeyFile != null) ''
        if [ -f "${peer.presharedKeyFile}" ]; then
          PSK=$(cat "${peer.presharedKeyFile}")
          sed -i "s|PLACEHOLDER_PSK_${peer.publicKey}|$PSK|g" /etc/wireguard/${cfg.interfaceName}.conf
        else
          echo "WARNING: WireGuard preshared key file '${peer.presharedKeyFile}' not found" >&2
          sed -i "/PLACEHOLDER_PSK_${peer.publicKey}/d" /etc/wireguard/${cfg.interfaceName}.conf
        fi
      ''
    ) cfg.peers}
  '';

in
{
  options.services.wireguard = {
    enable = lib.mkEnableOption "WireGuard VPN tunnel";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.wireguard-tools;
      description = "The wireguard-tools package to use.";
    };

    interfaceName = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "Name of the WireGuard network interface.";
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/wireguard-private-key";
      description = "Path to the private key file (mounted at runtime).";
    };

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.0.0.1/24";
      description = "Address to assign to the WireGuard interface.";
    };

    listenPort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 51820;
      description = "UDP port to listen on. Null for random.";
    };

    dns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "1.1.1.1, 1.0.0.1";
      description = "DNS servers to use when the tunnel is active.";
    };

    mtu = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "MTU for the WireGuard interface.";
    };

    table = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Routing table to use (auto, off, or a number).";
    };

    postUp = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Commands to run after the interface is up.";
    };

    postDown = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Commands to run after the interface is down.";
    };

    peers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          publicKey = lib.mkOption {
            type = lib.types.str;
            description = "Public key of the peer.";
          };

          presharedKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path to the preshared key file for this peer.";
          };

          endpoint = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "vpn.example.com:51820";
            description = "Endpoint address of the peer.";
          };

          allowedIPs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "IP ranges to route through this peer.";
            example = [ "10.0.0.0/24" "0.0.0.0/0" ];
          };

          persistentKeepalive = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            example = 25;
            description = "Keepalive interval in seconds.";
          };
        };
      });
      default = [];
      description = "WireGuard peer configurations.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.peers != [];
        message = "services.wireguard: at least one peer must be configured.";
      }
    ];

    warnings = [
      "services.wireguard: Container must be run with --cap-add=NET_ADMIN --cap-add=NET_RAW for WireGuard to work."
    ];

    image.exposedPorts = lib.mkDefault (
      lib.optional (cfg.listenPort != null) cfg.listenPort
    );

    packages = [ cfg.package pkgs.iproute2 pkgs.iptables ];

    initScripts.wireguard-config = "${initWg}";

    s6Services.wireguard = {
      kind = "longrun";
      run = ''
        # Bring up the WireGuard interface using wg-quick
        ${cfg.package}/bin/wg-quick up /etc/wireguard/${cfg.interfaceName}.conf

        # wg-quick exits after setup; keep the service alive by monitoring
        # the interface. If it goes down, s6 will restart this service.
        while ${pkgs.iproute2}/bin/ip link show ${cfg.interfaceName} &>/dev/null; do
          sleep 30
        done
        echo "WireGuard interface ${cfg.interfaceName} went down" >&2
        exit 1
      '';
    };
  };
}
