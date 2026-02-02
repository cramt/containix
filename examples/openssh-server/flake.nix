# OpenSSH server example: SSH/SFTP access to a container.
#
# Build:  nix build .#container
# Load:   docker load < result
# Run:    docker run -p 2222:22 -v $(pwd)/ssh-keys:/etc/ssh openssh-server
#
# Connect: ssh -p 2222 root@localhost
{
  inputs.containix.url = "path:../..";

  outputs = { containix, nixpkgs, ... }: let
    mkContainer = containix.lib.x86_64-linux.mkContainer;
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    packages.x86_64-linux.container = mkContainer {
      image.name = "openssh-server";
      image.tag = "latest";

      # Add some useful tools for SSH sessions
      packages = with pkgs; [
        vim
        htop
        curl
        git
      ];

      services.openssh = {
        enable = true;
        port = 22;
        
        # Allow root login with public key only
        permitRootLogin = "prohibit-password";
        passwordAuthentication = false;
        pubkeyAuthentication = true;
        
        # Host keys will be auto-generated in /etc/ssh
        # Mount a volume to persist them across container restarts
        hostKeyDir = "/etc/ssh";
        
        extraConfig = ''
          # Allow TCP forwarding for tunneling
          AllowTcpForwarding yes
          
          # Keep connections alive
          ClientAliveInterval 60
          ClientAliveCountMax 3
        '';
      };

      # Expose SSH port
      image.exposedPorts = [ 22 ];
      
      # Declare volume for persistent host keys
      image.volumes = [ "/etc/ssh" ];
      
      # Add a welcome message
      files."etc/motd".text = ''
        ╔═══════════════════════════════════════╗
        ║   Welcome to Containix SSH Server    ║
        ║                                       ║
        ║   Built with Nix + s6-overlay        ║
        ╚═══════════════════════════════════════╝
      '';
      
      # Set up authorized_keys from a mounted secret
      # In production, mount your public key at /run/secrets/authorized_keys
      initScripts.setup-ssh = ''
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        
        if [ -f /run/secrets/authorized_keys ]; then
          cp /run/secrets/authorized_keys /root/.ssh/authorized_keys
          chmod 600 /root/.ssh/authorized_keys
          echo "Loaded authorized_keys from /run/secrets/authorized_keys"
        else
          echo "WARNING: No authorized_keys found at /run/secrets/authorized_keys"
          echo "Mount your public key there to enable SSH access"
        fi
      '';
    };
  };
}
