# OpenSSH Server Example

This example demonstrates a container with OpenSSH server for SSH/SFTP access.

## Features

- OpenSSH server with public key authentication
- Auto-generated host keys (persisted via volume)
- SFTP support
- Useful tools pre-installed (vim, htop, curl, git)
- TCP forwarding enabled for tunneling

## Build and Run

```bash
# Build the image
nix build .#container

# Load into Docker
docker load < result

# Generate an SSH key pair for testing (if you don't have one)
ssh-keygen -t ed25519 -f ./test_key -N ""

# Create a directory for persistent host keys
mkdir -p ssh-keys

# Run the container
docker run -d \
  --name ssh-server \
  -p 2222:22 \
  -v $(pwd)/ssh-keys:/etc/ssh \
  -v $(pwd)/test_key.pub:/run/secrets/authorized_keys:ro \
  openssh-server

# Connect via SSH
ssh -i ./test_key -p 2222 root@localhost

# Or use SFTP
sftp -i ./test_key -P 2222 root@localhost
```

## Configuration

The example shows:

- **Public key authentication only** — No password login
- **Root login** — Allowed with public key (`prohibit-password`)
- **Persistent host keys** — Mounted volume at `/etc/ssh`
- **Authorized keys** — Loaded from `/run/secrets/authorized_keys`
- **TCP forwarding** — Enabled for SSH tunneling

## Production Usage

For production:

1. **Mount your authorized_keys**:
   ```bash
   -v /path/to/authorized_keys:/run/secrets/authorized_keys:ro
   ```

2. **Persist host keys** to avoid "host key changed" warnings:
   ```bash
   -v /path/to/ssh-keys:/etc/ssh
   ```

3. **Use a non-standard port** if running multiple SSH servers:
   ```nix
   services.openssh.port = 2222;
   ```

4. **Restrict root login** or create additional users:
   ```nix
   services.openssh.permitRootLogin = "no";
   ```

## Customization

See `flake.nix` for available options. Key settings:

- `services.openssh.port` — SSH port (default: 22)
- `services.openssh.permitRootLogin` — Root login policy
- `services.openssh.passwordAuthentication` — Enable/disable passwords
- `services.openssh.extraConfig` — Additional sshd_config directives
