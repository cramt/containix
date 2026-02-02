# services.openssh – OpenSSH server for SSH/SFTP access.
#
# Provides SSH and SFTP access to containers. Useful for:
# - Remote administration and debugging
# - SFTP file transfers
# - Port forwarding and tunneling
{ lib, pkgs, config, ... }:

let
  cfg = config.services.openssh;

  # Generate sshd_config
  sshdConfig = pkgs.writeText "sshd_config" ''
    # Basic settings
    Port ${toString cfg.port}
    ${lib.optionalString (cfg.listenAddress != null) "ListenAddress ${cfg.listenAddress}"}
    
    # Host keys
    ${lib.concatMapStringsSep "\n" (key: "HostKey ${key}") cfg.hostKeys}
    
    # Authentication
    PermitRootLogin ${cfg.permitRootLogin}
    PasswordAuthentication ${if cfg.passwordAuthentication then "yes" else "no"}
    PubkeyAuthentication ${if cfg.pubkeyAuthentication then "yes" else "no"}
    ${lib.optionalString (cfg.authorizedKeysFiles != [])
      "AuthorizedKeysFile ${lib.concatStringsSep " " cfg.authorizedKeysFiles}"}
    
    # Security settings
    PermitEmptyPasswords no
    ChallengeResponseAuthentication no
    UsePAM ${if cfg.usePAM then "yes" else "no"}
    X11Forwarding ${if cfg.x11Forwarding then "yes" else "no"}
    
    # Subsystems
    Subsystem sftp ${cfg.package}/libexec/sftp-server ${cfg.sftpFlags}
    
    # Logging
    SyslogFacility AUTH
    LogLevel ${cfg.logLevel}
    
    # Runtime directory (non-root compatible)
    PidFile /tmp/sshd.pid
    
    ${cfg.extraConfig}
  '';

  # Init script to generate host keys if they don't exist
  initHostKeys = pkgs.writeShellScript "init-ssh-host-keys" ''
    set -e
    mkdir -p ${cfg.hostKeyDir}
    
    ${lib.concatMapStringsSep "\n" (keyPath:
      let
        keyType = if lib.hasSuffix "_ed25519_key" keyPath then "ed25519"
                  else if lib.hasSuffix "_rsa_key" keyPath then "rsa"
                  else if lib.hasSuffix "_ecdsa_key" keyPath then "ecdsa"
                  else "ed25519";
      in ''
        if [ ! -f "${keyPath}" ]; then
          echo "Generating ${keyType} host key: ${keyPath}"
          ${cfg.package}/bin/ssh-keygen -t ${keyType} -f "${keyPath}" -N "" -C "containix-host-key"
        fi
      ''
    ) cfg.hostKeys}
    
    # Set proper permissions
    chmod 700 ${cfg.hostKeyDir}
    chmod 600 ${cfg.hostKeyDir}/*_key
    chmod 644 ${cfg.hostKeyDir}/*_key.pub 2>/dev/null || true
  '';

in
{
  options.services.openssh = {
    enable = lib.mkEnableOption "OpenSSH server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openssh;
      description = "The OpenSSH package to use.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 22;
      description = "Port for SSH server to listen on.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "0.0.0.0";
      description = "Address to listen on. If null, listens on all interfaces.";
    };

    hostKeyDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssh";
      description = "Directory where host keys are stored.";
    };

    hostKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_rsa_key"
      ];
      description = "List of host key paths. Keys will be auto-generated if missing.";
    };

    permitRootLogin = lib.mkOption {
      type = lib.types.enum [ "yes" "no" "prohibit-password" "forced-commands-only" ];
      default = "prohibit-password";
      description = "Whether root can log in via SSH.";
    };

    passwordAuthentication = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow password authentication.";
    };

    pubkeyAuthentication = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow public key authentication.";
    };

    authorizedKeysFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/root/.ssh/authorized_keys" ];
      description = "Files to read authorized keys from.";
    };

    usePAM = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable PAM authentication (requires PAM setup in container).";
    };

    x11Forwarding = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable X11 forwarding.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "QUIET" "FATAL" "ERROR" "INFO" "VERBOSE" "DEBUG" "DEBUG1" "DEBUG2" "DEBUG3" ];
      default = "INFO";
      description = "SSH daemon log level.";
    };

    sftpFlags = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "-l INFO";
      description = "Additional flags for the SFTP subsystem.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra configuration lines appended to sshd_config.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.passwordAuthentication || cfg.pubkeyAuthentication;
        message = "services.openssh: At least one authentication method (passwordAuthentication or pubkeyAuthentication) must be enabled.";
      }
      {
        assertion = cfg.hostKeys != [];
        message = "services.openssh: hostKeys cannot be empty.";
      }
    ];

    # Auto-expose SSH port
    image.exposedPorts = lib.mkDefault [ cfg.port ];

    # sshd requires a privilege separation user
    image.users.sshd = {
      uid = 74;
      gid = 74;
      home = "/var/empty";
      shell = "/usr/sbin/nologin";
      description = "sshd privsep";
    };
    image.groups.sshd = { gid = 74; };

    packages = [ cfg.package ];

    files = [
      { source = sshdConfig; target = "etc/ssh/sshd_config"; }
    ];

    # Generate host keys and set up privsep dir before starting sshd
    initScripts.openssh-hostkeys = ''
      mkdir -p /var/empty
      chmod 755 /var/empty
      ${initHostKeys}
    '';

    s6Services.openssh = {
      kind = "longrun";
      run = ''
        # Ensure host keys exist (should be done by init script, but double-check)
        if [ ! -f "${builtins.head cfg.hostKeys}" ]; then
          echo "ERROR: Host keys not found. Init script may have failed."
          exit 1
        fi
        
        # Run sshd in foreground mode
        exec ${cfg.package}/bin/sshd -D -e -f /etc/ssh/sshd_config
      '';
    };
  };
}
