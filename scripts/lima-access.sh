#!/usr/bin/env bash
# Optional Mac/Lima access adapter; native Ubuntu clients use NodePort directly.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ "${EUID}" -eq 0 && -e /var/lib/mtc-devops/cluster.uid ]] || fail 'Dedicated lab + sudo required.'
id devops >/dev/null || fail 'This adapter expects the devops user from lab/ubuntu-arm64.yaml.'
export KUBECONFIG=/etc/kubernetes/admin.conf
[[ "$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')" == "$(cat /var/lib/mtc-devops/cluster.uid)" ]] || fail 'Wrong cluster.'
MTC_NODE_IP="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
[[ "${MTC_NODE_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected IPv4 node address.'
for MTC_PROTOCOL in http https; do
  case "${MTC_PROTOCOL}" in http) MTC_LISTEN_PORT=18080; MTC_NODE_PORT=30080;; https) MTC_LISTEN_PORT=18443; MTC_NODE_PORT=30443;; esac
  cat >"/etc/systemd/system/mtc-lima-${MTC_PROTOCOL}.service" <<EOF
[Unit]
Description=MTC Lima ${MTC_PROTOCOL} adapter to Gateway NodePort
After=network-online.target
Wants=network-online.target

[Service]
User=devops
ExecStart=/usr/bin/socat TCP-LISTEN:${MTC_LISTEN_PORT},bind=0.0.0.0,reuseaddr,fork TCP:${MTC_NODE_IP}:${MTC_NODE_PORT}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
systemctl enable --now mtc-lima-http mtc-lima-https
kubectl apply -f "${PROJECT_ROOT}/lab/localhost-route.yaml"
log 'Lima adapter ready: localhost:18080 HTTP, 18443 raw TLS. Gateway still handles all routing.'
