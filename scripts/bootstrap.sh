#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ "${EUID}" -eq 0 ]] || fail 'Run bootstrap with sudo on the dedicated Ubuntu host.'
[[ "${1:-}" == '--dedicated-host' ]] || fail 'Pass --dedicated-host to acknowledge that this Ubuntu is reserved for the lab.'
source /etc/os-release
[[ "${ID}" == ubuntu && "${VERSION_ID}" == 24.04 ]] || fail 'Only Ubuntu 24.04 is supported by this bootstrap.'
[[ "$(uname -m)" == aarch64 || "$(uname -m)" == x86_64 ]] || fail 'Supported CPU architectures: arm64 and amd64.'
if [[ -e /etc/kubernetes/admin.conf && ! -e /var/lib/mtc-devops/managed ]]; then
  fail 'An existing Kubernetes cluster was found. It will not be modified.'
fi
if [[ -e /etc/kubernetes/admin.conf ]]; then
  MTC_PREFLIGHT_VERSION="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
  [[ "${MTC_PREFLIGHT_VERSION}" == "${KUBERNETES_VERSION}" ]] || fail 'Existing cluster version differs; no host changes were made.'
  if [[ -e /var/lib/mtc-devops/cluster.uid ]]; then
    [[ "$(cat /var/lib/mtc-devops/cluster.uid)" == "$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')" ]] || fail 'Cluster identity differs; no host changes were made.'
  fi
fi
MTC_OWNER="${SUDO_USER:-root}"
MTC_OWNER_HOME="$(getent passwd "${MTC_OWNER}" | cut -d: -f6)"
if [[ -e "${MTC_OWNER_HOME}/.kube/config" ]] && ! cmp -s /etc/kubernetes/admin.conf "${MTC_OWNER_HOME}/.kube/config"; then
  fail 'An unrelated kubeconfig already exists; no host changes were made.'
fi
[[ -z "$(swapon --noheadings --show)" ]] || fail 'Disable swap on this dedicated host before continuing.'
[[ "$(nproc)" -ge 2 ]] || fail 'At least 2 CPUs are required.'
[[ "$(awk '/MemTotal/ {print $2}' /proc/meminfo)" -ge 6000000 ]] || fail 'At least 6 GiB RAM is required for the complete stack.'
[[ "$(df --output=avail -k / | tail -1)" -ge 10000000 ]] || fail 'At least 10 GB free space is required.'
install -d -m 700 /var/lib/mtc-devops
exec 9>/var/lib/mtc-devops/bootstrap.lock
flock -n 9 || fail 'Another bootstrap is running.'
touch /var/lib/mtc-devops/managed
export DEBIAN_FRONTEND=noninteractive

log 'Install host dependencies on the dedicated Ubuntu'
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gnupg python3 python3-yaml make openssl conntrack socat "containerd=${CONTAINERD_DEB_VERSION}" "runc=${RUNC_DEB_VERSION}"
printf 'overlay\nbr_netfilter\n' >/etc/modules-load.d/mtc-kubernetes.conf
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-mtc-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

log 'Configure containerd with the systemd cgroup driver'
install -d -m 755 /etc/containerd
containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' >/var/lib/mtc-devops/containerd.toml
if ! cmp -s /var/lib/mtc-devops/containerd.toml /etc/containerd/config.toml; then
  if [[ -e /etc/containerd/config.toml && ! -e /var/lib/mtc-devops/containerd.original.toml ]]; then
    cp -p /etc/containerd/config.toml /var/lib/mtc-devops/containerd.original.toml
  fi
  install -m 644 /var/lib/mtc-devops/containerd.toml /etc/containerd/config.toml
  systemctl restart containerd
fi
systemctl enable --now containerd

log "Install pinned Kubernetes ${KUBERNETES_VERSION}"
install -d -m 755 /etc/apt/keyrings
curl --fail --silent --show-error --location --retry 3 "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" -o /var/lib/mtc-devops/kubernetes-release.key
gpg --dearmor --batch --yes --output /etc/apt/keyrings/mtc-kubernetes.gpg /var/lib/mtc-devops/kubernetes-release.key
printf 'deb [signed-by=/etc/apt/keyrings/mtc-kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' "${KUBERNETES_MINOR}" >/etc/apt/sources.list.d/mtc-kubernetes.list
apt-get update -qq
apt-get install -y --allow-change-held-packages "kubelet=${KUBERNETES_DEB_VERSION}" "kubeadm=${KUBERNETES_DEB_VERSION}" "kubectl=${KUBERNETES_DEB_VERSION}"
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

if [[ ! -e /etc/kubernetes/admin.conf ]]; then
  MTC_NODE_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
  [[ -n "${MTC_NODE_IP}" ]] || fail 'Could not determine the primary IPv4 address.'
  cat >/var/lib/mtc-devops/kubeadm.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${MTC_NODE_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_VERSION}
clusterName: mtc-engineer-hack
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
  if ! kubeadm init --config /var/lib/mtc-devops/kubeadm.yaml >/var/lib/mtc-devops/kubeadm-init.log 2>&1; then
    tail -60 /var/lib/mtc-devops/kubeadm-init.log >&2
    fail 'kubeadm init failed; see the private log in /var/lib/mtc-devops.'
  fi
fi
export KUBECONFIG=/etc/kubernetes/admin.conf
CURRENT_VERSION="$(kubectl version -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
[[ "${CURRENT_VERSION}" == "${KUBERNETES_VERSION}" ]] || fail "Cluster version ${CURRENT_VERSION} differs from pinned ${KUBERNETES_VERSION}; no upgrade was attempted."
MTC_CLUSTER_UID="$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')"
if [[ -e /var/lib/mtc-devops/cluster.uid ]]; then
  [[ "$(cat /var/lib/mtc-devops/cluster.uid)" == "${MTC_CLUSTER_UID}" ]] || fail 'Cluster identity differs from the original managed lab.'
else
  printf '%s' "${MTC_CLUSTER_UID}" >/var/lib/mtc-devops/cluster.uid
fi

log "Install Calico ${CALICO_VERSION}"
curl --fail --silent --show-error --location --retry 3 "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" -o /var/lib/mtc-devops/calico.upstream.yaml
python3 - /var/lib/mtc-devops/calico.upstream.yaml /var/lib/mtc-devops/calico.yaml <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
needle = '# - name: CALICO_IPV4POOL_CIDR\n            #   value: "192.168.0.0/16"'
if needle not in text:
    raise SystemExit('Calico upstream structure changed; refusing a guessed edit.')
text = text.replace(needle, '- name: CALICO_IPV4POOL_CIDR\n              value: "10.244.0.0/16"')
Path(sys.argv[2]).write_text(text)
PY
kubectl apply --server-side -f /var/lib/mtc-devops/calico.yaml
if kubectl get node "$(hostname)" -o json | python3 -c 'import json,sys; t=json.load(sys.stdin)["spec"].get("taints",[]); sys.exit(0 if any(x["key"]=="node-role.kubernetes.io/control-plane" for x in t) else 1)'; then
  kubectl taint node "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule-
fi
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout=300s

log "Install Helm ${HELM_VERSION} with checksum verification"
case "$(uname -m)" in aarch64) MTC_ARCH=arm64;; x86_64) MTC_ARCH=amd64;; esac
MTC_HELM_ARCHIVE="helm-${HELM_VERSION}-linux-${MTC_ARCH}.tar.gz"
curl --fail --silent --show-error --location --retry 3 "https://get.helm.sh/${MTC_HELM_ARCHIVE}" -o "/var/lib/mtc-devops/${MTC_HELM_ARCHIVE}"
curl --fail --silent --show-error --location --retry 3 "https://get.helm.sh/${MTC_HELM_ARCHIVE}.sha256sum" -o "/var/lib/mtc-devops/${MTC_HELM_ARCHIVE}.sha256sum"
(cd /var/lib/mtc-devops && sha256sum --check "${MTC_HELM_ARCHIVE}.sha256sum")
tar -xzf "/var/lib/mtc-devops/${MTC_HELM_ARCHIVE}" -C /var/lib/mtc-devops
install -m 755 "/var/lib/mtc-devops/linux-${MTC_ARCH}/helm" /usr/local/bin/helm

install -d -m 700 -o "${MTC_OWNER}" "${MTC_OWNER_HOME}/.kube"
if [[ -e "${MTC_OWNER_HOME}/.kube/config" ]] && ! cmp -s /etc/kubernetes/admin.conf "${MTC_OWNER_HOME}/.kube/config"; then
  fail 'An unrelated kubeconfig already exists; it was not overwritten.'
fi
install -m 600 -o "${MTC_OWNER}" /etc/kubernetes/admin.conf "${MTC_OWNER_HOME}/.kube/config"
log 'Bootstrap complete. Run make deploy as the regular lab user.'
