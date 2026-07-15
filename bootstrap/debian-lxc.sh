#!/usr/bin/env bash

set -Eeuo pipefail

BOOTSTRAP_VERSION="1.0.0"
TOTAL_STEPS=8
START_TIME=$SECONDS
INSTALL_PORTAINER="true"

step() {
    printf '\n[%s/%s] %s\n' "$1" "$TOTAL_STEPS" "$2"
}

done_message() {
    printf '✓ Done\n'
}

error_handler() {
    local exit_code=$?

    printf '\n✗ Bootstrap failed on or near line %s.\n' \
        "${BASH_LINENO[0]}"
    printf 'Exit code: %s\n' "$exit_code"

    exit "$exit_code"
}

trap error_handler ERR

clear

echo "================================="
echo " Joshua Homelab Bootstrap"
echo " Debian LXC"
echo " Version $BOOTSTRAP_VERSION"
echo "================================="

# Debian LXC templates normally start with a root account.
# Requiring root also avoids depending on sudo being installed.
if [[ $EUID -ne 0 ]]; then
    echo
    echo "Run this bootstrap as root."
    echo
    echo "Example:"
    echo "  su -"
    echo "  bash /path/to/debian-lxc.sh"
    exit 1
fi

# Portainer is installed by default.
# Use --no-portainer for a deliberately unmanaged Docker host.
for argument in "$@"; do
    case "$argument" in
        --no-portainer)
            INSTALL_PORTAINER="false"
            ;;
        *)
            echo "Unknown argument: $argument"
            echo "Supported argument: --no-portainer"
            exit 1
            ;;
    esac
done

step 1 "Checking Debian and LXC..."

if [[ ! -f /etc/os-release ]]; then
    echo "Unable to identify the operating system."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    echo "This bootstrap supports Debian only."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

VIRTUALISATION="$(systemd-detect-virt 2>/dev/null || true)"

if [[ "$VIRTUALISATION" != "lxc" ]]; then
    echo "This bootstrap is intended for an LXC container."
    echo "Detected virtualisation: ${VIRTUALISATION:-none}"
    exit 1
fi

echo "Detected: $PRETTY_NAME"
echo "Virtualisation: LXC"
done_message

step 2 "Updating system..."

apt update
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
apt autoremove -y
apt autoclean

done_message

step 3 "Installing required packages..."

# Only the packages needed to add Docker's signed repository.
DEBIAN_FRONTEND=noninteractive apt install -y \
    curl \
    ca-certificates \
    gnupg

done_message

step 4 "Installing Docker..."

# Create the directory used for third-party repository keys.
install -m 0755 -d /etc/apt/keyrings

# Install Docker's official Debian repository key.
curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor --yes \
        -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker's official Debian repository.
cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPOSITORY
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
DOCKER_REPOSITORY

apt update

DEBIAN_FRONTEND=noninteractive apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker

done_message

step 5 "Configuring Docker..."

# Keep container logs from consuming the LXC filesystem.
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

step 6 "Creating Docker directories..."

# Each Compose project gets its own directory beneath /opt/docker.
mkdir -p /opt/docker

# Future root login shells begin in the Docker project directory.
PROFILE_FILE="/root/.profile"

touch "$PROFILE_FILE"

if ! grep -qxF 'cd /opt/docker' "$PROFILE_FILE"; then
    echo 'cd /opt/docker' >> "$PROFILE_FILE"
fi

done_message

step 7 "Installing Portainer Agent..."

if [[ "$INSTALL_PORTAINER" == "true" ]]; then
    mkdir -p /opt/docker/portainer-agent

    cat > /opt/docker/portainer-agent/compose.yml \
        <<'PORTAINER_COMPOSE'
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
else
    echo "Portainer Agent skipped."
fi

done_message

step 8 "Running checks..."

docker --version
docker compose version
systemctl is-active --quiet docker

if [[ "$INSTALL_PORTAINER" == "true" ]] &&
   docker inspect \
       -f '{{.State.Running}}' \
       portainer-agent 2>/dev/null |
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
echo "Operating system:  $PRETTY_NAME"
echo "Working directory: /opt/docker"
echo "Docker:            Installed"
echo "Portainer agent:   $PORTAINER_STATUS"
echo "Elapsed time:      ${ELAPSED_TIME}s"
echo
echo "The LXC is ready to host Docker Compose projects."
echo
echo "A reboot is recommended:"
echo
echo "  reboot"
echo
