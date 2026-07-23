#!/usr/bin/env bash

set -Eeuo pipefail

K8S_MINOR="${K8S_MINOR:-v1.28}"
CRI_SOCKET="unix:///run/containerd/containerd.sock"

JOIN_COMMAND="${*:-}"

log() {
    echo
    echo "==> $1"
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

if [[ "$EUID" -ne 0 ]]; then
    fail "Run this script with sudo."
fi

if [[ -z "$JOIN_COMMAND" ]]; then
    cat <<EOF
Usage:

sudo ./setup-worker.sh kubeadm join CONTROL_PLANE_IP:6443 \
  --token TOKEN \
  --discovery-token-ca-cert-hash sha256:HASH
EOF

    exit 1
fi

if [[ "$JOIN_COMMAND" != kubeadm\ join* ]] &&
   [[ "$JOIN_COMMAND" != sudo\ kubeadm\ join* ]]; then
    fail "You must provide a valid kubeadm join command."
fi

export DEBIAN_FRONTEND=noninteractive

log "Updating packages"

apt-get update

apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gpg \
    containerd

log "Disabling swap"

swapoff -a
sed -Ei '/^[^#].*[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab

log "Configuring kernel modules"

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

log "Configuring Kubernetes networking"

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

log "Configuring containerd"

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

sed -i \
    's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

systemctl enable --now containerd
systemctl restart containerd

if ! systemctl is-active --quiet containerd; then
    fail "containerd failed to start."
fi

log "Adding Kubernetes repository ${K8S_MINOR}"

mkdir -p -m 755 /etc/apt/keyrings

rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg

curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
    gpg --dearmor \
        -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /
EOF

apt-get update

log "Installing Kubernetes components"

apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true

apt-get install -y kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

log "Verifying prerequisites"

[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] ||
    fail "IP forwarding is disabled."

lsmod | grep -q '^overlay' ||
    fail "overlay module is not loaded."

lsmod | grep -q '^br_netfilter' ||
    fail "br_netfilter module is not loaded."

if swapon --show | grep -q .; then
    fail "Swap is still enabled."
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo "This worker is already joined to a Kubernetes cluster."
    exit 0
fi

JOIN_COMMAND="${JOIN_COMMAND#sudo }"

if [[ "$JOIN_COMMAND" != *"--cri-socket"* ]]; then
    JOIN_COMMAND+=" --cri-socket ${CRI_SOCKET}"
fi

log "Joining worker to the cluster"

bash -c "$JOIN_COMMAND"

log "Worker setup completed successfully"

echo "Return to the control plane and run:"
echo
echo "kubectl get nodes -o wide"
