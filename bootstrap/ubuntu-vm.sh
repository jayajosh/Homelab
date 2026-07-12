#!/usr/bin/env bash

set -Eeuo pipefail

TOTAL_STEPS=8
ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)"

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
echo "================================="

if [[ $EUID -ne 0 ]]; then
    echo
    echo "Restarting with sudo..."
    exec sudo -E bash "$0" "$@"
fi

step 1 "Updating system..."
apt update
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y
apt autoremove -y
apt autoclean
done_message

step 2 "Installing packages..."
DEBIAN_FRONTEND=noninteractive apt install -y \
    qemu-guest-agent \
    curl \
    ca-certificates \
    gnupg \
    git \
    nano \
    htop \
    tree \
    unzip
done_message

step 3 "Installing Docker..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

cat > /etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
DOCKER_REPO

apt update

DEBIAN_FRONTEND=noninteractive apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker
done_message

step 4 "Configuring Docker..."

install -m 0755 -d /etc/docker

cat > /etc/docker/daemon.json <<'DOCKER_CONFIG'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DOCKER_CONFIG

systemctl restart docker
done_message

step 5 "Creating folder structure..."

mkdir -p \
    /opt/docker \
    /srv/data \
    /srv/backups \
    /srv/downloads

chown -R "$ORIGINAL_USER:$ORIGINAL_USER" \
    /opt/docker \
    /srv/data \
    /srv/backups \
    /srv/downloads

done_message

step 6 "Configuring user access..."

usermod -aG docker "$ORIGINAL_USER"

PROFILE_FILE="$ORIGINAL_HOME/.profile"

touch "$PROFILE_FILE"

if ! grep -qxF 'cd /opt/docker' "$PROFILE_FILE"; then
    echo 'cd /opt/docker' >> "$PROFILE_FILE"
fi

chown "$ORIGINAL_USER:$ORIGINAL_USER" "$PROFILE_FILE"
done_message

step 7 "Enabling QEMU Guest Agent..."

systemctl enable --now qemu-guest-agent
done_message

step 8 "Running checks..."

docker --version
docker compose version
systemctl is-active --quiet docker
systemctl is-active --quiet qemu-guest-agent
done_message

echo
echo "================================="
echo " Bootstrap complete"
echo "================================="
echo
echo "User:              $ORIGINAL_USER"
echo "Working directory: /opt/docker"
echo "Docker:            Installed"
echo "QEMU agent:        Running"
echo
echo "Reboot the VM before using Docker"
echo "without sudo:"
echo
echo "  sudo reboot"
echo
