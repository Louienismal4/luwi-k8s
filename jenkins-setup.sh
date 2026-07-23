#!/usr/bin/env bash
set -Eeuo pipefail

# Summitodoro Jenkins CI server — latest stable packages
# Target: Ubuntu 24.04 LTS
#
# Installs the newest packages currently available from:
#   - Jenkins LTS repository
#   - Docker stable repository
#   - Trivy repository
#   - Ubuntu repository
#
# Jenkins currently requires Java 21 or 25. Ubuntu 24.04 provides
# OpenJDK 21 as the current broadly supported server runtime.

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }
trap 'die "Setup failed at line $LINENO."' ERR

[[ "$EUID" -eq 0 ]] || die "Run with sudo or as root."
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This script supports Ubuntu only."

export DEBIAN_FRONTEND=noninteractive

log "Updating Ubuntu"
apt-get update
apt-get full-upgrade -y

log "Installing base tools and Java"
apt-get install -y \
  ca-certificates \
  curl \
  wget \
  gnupg \
  git \
  jq \
  unzip \
  fontconfig \
  openjdk-21-jre-headless

log "Configuring latest Jenkins LTS repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  -o /etc/apt/keyrings/jenkins-keyring.asc
chmod 0644 /etc/apt/keyrings/jenkins-keyring.asc

cat > /etc/apt/sources.list.d/jenkins.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/
EOF

log "Removing conflicting Docker packages"
for package in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt-get remove -y "$package" 2>/dev/null || true
done

log "Configuring Docker stable repository"
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

log "Configuring Trivy repository"
curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/trivy.gpg
chmod 0644 /etc/apt/keyrings/trivy.gpg

cat > /etc/apt/sources.list.d/trivy.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main
EOF

log "Installing latest stable Jenkins, Docker, and Trivy"
apt-get update
apt-get install -y \
  jenkins \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  trivy

log "Enabling services"
systemctl daemon-reload
systemctl enable --now docker
systemctl enable --now jenkins

log "Allowing Jenkins to use Docker"
usermod -aG docker jenkins
systemctl restart jenkins

log "Verifying"
java -version
jenkins --version || true
docker --version
docker buildx version
docker compose version
trivy --version

runuser -u jenkins -- docker info >/dev/null \
  || die "Jenkins cannot access Docker."

PASSWORD_FILE="/var/lib/jenkins/secrets/initialAdminPassword"

cat <<EOF

Setup complete.

Jenkins:
  http://<JENKINS_SERVER_IP>:8080

Initial password:
  sudo cat ${PASSWORD_FILE}

Security group:
  Allow TCP 8080 only from your public IP.
EOF
