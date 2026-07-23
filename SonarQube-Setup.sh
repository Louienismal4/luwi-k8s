#!/usr/bin/env bash
set -Eeuo pipefail

# Summitodoro SonarQube server — latest stable container images
# Target: Ubuntu 24.04 LTS
#
# Uses:
#   sonarqube:latest
#   postgres:18.4-alpine
#
# Note: Using moving "latest" tags is convenient for a lab, but production
# environments should pin tested image versions or digests.

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }
trap 'die "Setup failed at line $LINENO."' ERR

[[ "$EUID" -eq 0 ]] || die "Run with sudo or as root."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only."

export DEBIAN_FRONTEND=noninteractive
INSTALL_DIR="/opt/summitodoro-sonarqube"

log "Updating Ubuntu"
apt-get update
apt-get full-upgrade -y
apt-get install -y ca-certificates curl gnupg openssl

log "Removing conflicting Docker packages"
for package in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "$package" 2>/dev/null || true
done

log "Configuring Docker stable repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
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

log "Installing latest Docker stable packages"
apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

log "Applying SonarQube host requirements"
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl --system >/dev/null

log "Creating deployment"
install -d -m 0750 "$INSTALL_DIR"

if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cat > "$INSTALL_DIR/.env" <<EOF
POSTGRES_DB=sonarqube
POSTGRES_USER=sonarqube
POSTGRES_PASSWORD=$(openssl rand -hex 24)
EOF
  chmod 0600 "$INSTALL_DIR/.env"
fi

cat > "$INSTALL_DIR/compose.yaml" <<'EOF'
services:
  sonarqube:
    image: sonarqube:latest
    container_name: summitodoro-sonarqube
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://postgres:5432/${POSTGRES_DB}
      SONAR_JDBC_USERNAME: ${POSTGRES_USER}
      SONAR_JDBC_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "9000:9000"
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_extensions:/opt/sonarqube/extensions
      - sonarqube_logs:/opt/sonarqube/logs
    ulimits:
      nofile:
        soft: 131072
        hard: 131072
      nproc: 8192
    stop_grace_period: 1h
    networks:
      - sonar

  postgres:
    image: postgres:18.4-alpine
    container_name: summitodoro-sonarqube-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 20
    volumes:
      - postgres_data:/var/lib/postgresql
    networks:
      - sonar

volumes:
  sonarqube_data:
  sonarqube_extensions:
  sonarqube_logs:
  postgres_data:

networks:
  sonar:
EOF

log "Pulling latest images and starting services"
cd "$INSTALL_DIR"
docker compose pull
docker compose up -d
docker compose ps

cat <<EOF

Setup started.

SonarQube:
  http://<SONARQUBE_SERVER_IP>:9000

Initial login:
  admin / admin

Logs:
  cd ${INSTALL_DIR}
  sudo docker compose logs -f sonarqube

Security group:
  Allow TCP 9000 only from your IP and the Jenkins security group.
EOF
