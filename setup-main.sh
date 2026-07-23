#!/usr/bin/env bash

set -Eeuo pipefail

K8S_MINOR="${K8S_MINOR:-v1.28}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
CRI_SOCKET="unix:///run/containerd/containerd.sock"
KUBE_USER="${KUBE_USER:-ubuntu}"

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

if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo "Control plane is already initialized."
else
    CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-$(hostname -I | awk '{print $1}')}"

    log "Pulling Kubernetes images"

    kubeadm config images pull \
        --cri-socket "$CRI_SOCKET"

    log "Initializing control plane at ${CONTROL_PLANE_IP}"

    kubeadm init \
        --apiserver-advertise-address="$CONTROL_PLANE_IP" \
        --pod-network-cidr="$POD_CIDR" \
        --cri-socket="$CRI_SOCKET"
fi

log "Configuring kubectl for root"

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

if id "$KUBE_USER" >/dev/null 2>&1; then
    USER_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
    USER_GROUP="$(id -gn "$KUBE_USER")"

    log "Configuring kubectl for ${KUBE_USER}"

    mkdir -p "$USER_HOME/.kube"
    cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown -R "$KUBE_USER:$USER_GROUP" "$USER_HOME/.kube"
    chmod 600 "$USER_HOME/.kube/config"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

log "Installing Flannel"

kubectl apply -f \
    https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

log "Waiting for Kubernetes system pods"

sleep 15

kubectl get nodes -o wide
kubectl get pods -A

log "Generating worker join command"

JOIN_COMMAND="$(kubeadm token create --print-join-command)"

echo
echo "============================================================"
echo "Run this command on every worker node:"
echo
echo "sudo ${JOIN_COMMAND} --cri-socket ${CRI_SOCKET}"
echo "============================================================"
