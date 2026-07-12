#!/usr/bin/env bash

set -Eeuo pipefail

BOOTSTRAP_VERSION="1.1.0"
TOTAL_STEPS=9

ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)"
START_TIME=$SECONDS
INSTALL_PORTAINER="false"

step() {
    printf '\n[%s/%s] %s\n' "$1" "$TOTAL_STEPS" "$2"
}

done_message() {
    printf '✓ Done\n'
}

error_handler() {
    local exit_code=$?

    printf '\n✗ Bootstrap failed on or near line %s.\n' "${BASH_LINENO[0]}"
    printf 'Exit code: %s\n' "$exit_code"

    exit "$exit_code"
}

trap error_handler ERR

clear

echo "================================="
echo " Joshua Homelab Bootstrap"
echo " Ubuntu VM"
echo " Version $BOOTSTRAP_VERSION"
echo "================================="

# Relaunch the script as root when it was started by a normal user.
if [[ $EUID -ne 0 ]]; then
    echo
    echo "Restarting with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# Identify the normal user who launched the bootstrap.
if [[ "$ORIGINAL_USER" == "root" ]]; then
    echo
    echo "Warning: no non-root user was detected."
    echo "Docker access and the login directory will be configured for root."
fi

# Ask whether this VM should run the Portainer Agent.
echo
read -rp "Install Portainer Agent? [Y/n]: " PORTAINER_CHOICE

case "${PORTAINER_CHOICE:-Y}" in
    [Yy]|[Yy][Ee][Ss])
        INSTALL_PORTAINER="true"
        ;;
    *)
        INSTALL_PORTAINER="false"
        ;;
esac

step 1 "Checking Ubuntu..."

if [[ ! -f /etc/os-release ]]; then
    echo "Unable to identify the operating system."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "This bootstrap supports Ubuntu only."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

echo "Detected: $PRETTY_NAME"
done_message

step 2 "Updating system..."

# Refresh package information and install current updates.
apt update
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
apt autoremove -y
apt autoclean

done_message

step 3 "Installing required packages..."

# Only packages required for Docker installation and Proxmox integration.
DEBIAN_FRONTEND=noninteractive apt install -y \
    qemu-guest-agent \
    curl \
    ca-certificates \
    gnupg

done_message

step 4 "Installing Docker..."

# Create the secure directory used for repository signing keys.
install -m 0755 -d /etc/apt/keyrings

# Download and install Docker's official repository signing key.
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker's official Ubuntu repository.
cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPOSITORY
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
DOCKER_REPOSITORY

apt update

# Install Docker Engine, Compose and Buildx.
DEBIAN_FRONTEND=noninteractive apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker

done_message

step 5 "Configuring Docker..."

# Rotate container logs automatically to prevent them filling the VM disk.
install -m 0755 -d /etc/docker

cat > /etc/docker/daemon.json <<'DOCKER_CONFIGURATION'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKER_CONFIGURATION

systemctl restart docker

done_message

step 6 "Creating the Docker directory..."

# All Compose projects on the VM will live below /opt/docker.
mkdir -p /opt/docker

chown -R "$ORIGINAL_USER:$ORIGINAL_USER" /opt/docker

done_message

step 7 "Configuring user access..."

# Allow the normal user to run Docker without sudo after reconnecting.
usermod -aG docker "$ORIGINAL_USER"

PROFILE_FILE="$ORIGINAL_HOME/.profile"

touch "$PROFILE_FILE"

# Start future login sessions inside /opt/docker.
if ! grep -qxF 'cd /opt/docker' "$PROFILE_FILE"; then
    echo 'cd /opt/docker' >> "$PROFILE_FILE"
fi

chown "$ORIGINAL_USER:$ORIGINAL_USER" "$PROFILE_FILE"

done_message

step 8 "Starting QEMU Guest Agent..."

# Ubuntu starts this service through its existing systemd integration.
# It does not need to be enabled manually.
systemctl start qemu-guest-agent || true

done_message

step 9 "Installing optional services and running checks..."

if [[ "$INSTALL_PORTAINER" == "true" ]]; then
    mkdir -p /opt/docker/portainer-agent

    cat > /opt/docker/portainer-agent/compose.yml <<'PORTAINER_COMPOSE'
services:
  portainer-agent:
    image: portainer/agent:latest
    container_name: portainer-agent
    restart: unless-stopped

    ports:
      - "9001:9001"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
      - /:/host
PORTAINER_COMPOSE

    docker compose \
        -f /opt/docker/portainer-agent/compose.yml \
        up -d

    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" \
        /opt/docker/portainer-agent
fi

docker --version
docker compose version
systemctl is-active --quiet docker

if systemctl is-active --quiet qemu-guest-agent; then
    QEMU_STATUS="Running"
else
    QEMU_STATUS="Not running"
fi

if [[ "$INSTALL_PORTAINER" == "true" ]] &&
   docker inspect -f '{{.State.Running}}' portainer-agent 2>/dev/null |
       grep -qxF 'true'; then
    PORTAINER_STATUS="Running on port 9001"
else
    PORTAINER_STATUS="Not installed"
fi

done_message

ELAPSED_TIME=$((SECONDS - START_TIME))

echo
echo "================================="
echo " Bootstrap complete"
echo "================================="
echo
echo "Version:           $BOOTSTRAP_VERSION"
echo "Hostname:          $(hostname)"
echo "User:              $ORIGINAL_USER"
echo "Working directory: /opt/docker"
echo "Docker:            Installed"
echo "QEMU agent:        $QEMU_STATUS"
echo "Portainer agent:   $PORTAINER_STATUS"
echo "Elapsed time:      ${ELAPSED_TIME}s"
echo
echo "IMPORTANT:"
echo
echo "$ORIGINAL_USER has been added to the Docker group."
echo "Reboot or reconnect before running Docker without sudo:"
echo
echo "  sudo reboot"
echo
