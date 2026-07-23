#!/usr/bin/env bash
set -Eeuo pipefail

# Summitodoro Nexus Repository setup — latest stable packages
# Target: Ubuntu 24.04 LTS
#
# Installs Docker Engine from Docker's official stable repository and runs
# Sonatype Nexus Repository using the latest official container image.
#
# Recommended VM:
#   - Separate EC2 instance
#   - At least 2 vCPU
#   - At least 4 GB RAM
#   - At least 30 GB storage for a learning environment
#
# Run:
#   chmod +x setup-summitodoro-nexus-latest.sh
#   sudo ./setup-summitodoro-nexus-latest.sh

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$1"
}

die() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2
  exit 1
}

trap 'die "Setup failed at line $LINENO."' ERR

if [[ "${EUID}" -ne 0 ]]; then
  die "Run this script with sudo or as root."
fi

if [[ ! -f /etc/os-release ]]; then
  die "Cannot determine the operating system."
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  die "This script supports Ubuntu only."
fi

export DEBIAN_FRONTEND=noninteractive

INSTALL_DIR="/opt/summitodoro-nexus"
NEXUS_CONTAINER="summitodoro-nexus"

log "Updating Ubuntu packages"
apt-get update
apt-get full-upgrade -y

log "Installing required packages"
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  jq

log "Removing conflicting Docker packages when present"
for package in \
  docker.io \
  docker-doc \
  docker-compose \
  docker-compose-v2 \
  podman-docker \
  containerd \
  runc
do
  apt-get remove -y "$package" 2>/dev/null || true
done

log "Configuring Docker's official stable repository"
install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
  https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc

chmod 0644 /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

log "Installing the latest Docker stable packages"
apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

log "Creating the Nexus deployment"
install -d -m 0750 "$INSTALL_DIR"

cat > "$INSTALL_DIR/compose.yaml" <<'EOF'
services:
  nexus:
    image: sonatype/nexus3:latest
    container_name: summitodoro-nexus
    restart: unless-stopped
    ports:
      - "8081:8081"

      # Optional Docker registry connector.
      # Configure a Docker hosted repository in Nexus to use this port first.
      # - "8082:8082"

    environment:
      INSTALL4J_ADD_VM_PARAMS: >-
        -Xms1200m
        -Xmx1200m
        -XX:MaxDirectMemorySize=2g
        -Djava.util.prefs.userRoot=/nexus-data/javaprefs

    volumes:
      - nexus_data:/nexus-data

    stop_grace_period: 2m

volumes:
  nexus_data:
    name: summitodoro_nexus_data
EOF

chmod 0640 "$INSTALL_DIR/compose.yaml"

log "Pulling the latest Nexus image"
cd "$INSTALL_DIR"
docker compose pull

log "Starting Nexus"
docker compose up -d

log "Waiting for the Nexus container to start"
for _ in $(seq 1 60); do
  STATUS="$(
    docker inspect \
      --format '{{.State.Status}}' \
      "$NEXUS_CONTAINER" 2>/dev/null || true
  )"

  if [[ "$STATUS" == "running" ]]; then
    break
  fi

  sleep 5
done

if [[ "$(
  docker inspect \
    --format '{{.State.Status}}' \
    "$NEXUS_CONTAINER" 2>/dev/null || true
)" != "running" ]]; then
  docker compose logs --tail=100 nexus || true
  die "Nexus did not start."
fi

docker compose ps

cat <<EOF

Summitodoro Nexus Repository setup has started successfully.

Open Nexus:
  http://<NEXUS_SERVER_IP>:8081

Nexus may take several minutes to become ready after the container starts.

Get the initial administrator password:
  sudo docker exec ${NEXUS_CONTAINER} cat /nexus-data/admin.password

Initial username:
  admin

Useful commands:
  cd ${INSTALL_DIR}
  sudo docker compose ps
  sudo docker compose logs -f nexus
  sudo docker compose restart
  sudo docker compose pull
  sudo docker compose up -d
  sudo docker compose down

Persistent storage:
  Docker volume: summitodoro_nexus_data

AWS security group:
  - Allow TCP 8081 only from your own public IP and the Jenkins VM.
  - Do not expose repository connector ports publicly.
  - If Kubernetes must pull images from Nexus, allow the selected registry
    connector port only from the Kubernetes node security group.

Summitodoro note:
  GitHub Container Registry is simpler for your current pipeline.
  Nexus is useful when you specifically want to demonstrate private artifact
  management, proxy repositories, dependency caching, and repository governance.
EOF
