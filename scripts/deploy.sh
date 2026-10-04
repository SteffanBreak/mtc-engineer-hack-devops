#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
prepare_state
for cmd in kubectl helm python3 openssl; do require_command "${cmd}"; done
kubectl cluster-info >/dev/null
[[ "$(sudo cat /var/lib/mtc-devops/cluster.uid)" == "$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')" ]] || fail 'The selected Kubernetes cluster does not belong to this dedicated lab.'
exec 9>"${STATE_DIR}/deploy.lock"
flock -n 9 || fail 'Another deployment is running.'

log 'Prepare project namespaces and persistent storage'
kubectl apply -f "${PROJECT_ROOT}/manifests/namespaces.yaml"
sudo bash "${PROJECT_ROOT}/scripts/storage.sh"
export MTC_NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
render "${PROJECT_ROOT}/manifests/storage.yaml" | kubectl apply -f -

log 'Prepare local TLS and Grafana credentials'
bash "${PROJECT_ROOT}/scripts/tls.sh"
if ! kubectl -n mtc-observability get secret mtc-grafana-admin >/dev/null 2>&1; then
  umask 077
  printf 'admin' >"${STATE_DIR}/grafana-user"
  printf '%s' "$(openssl rand -hex 24)" >"${STATE_DIR}/grafana-password"
  kubectl -n mtc-observability create secret generic mtc-grafana-admin \
    --from-file=admin-user="${STATE_DIR}/grafana-user" \
    --from-file=admin-password="${STATE_DIR}/grafana-password" >/dev/null
fi

log "Install Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" --namespace envoy-gateway-system \
  --values "${PROJECT_ROOT}/values/envoy.yaml" --wait --timeout 5m

log 'Deploy Nginx and Gateway routes'
helm upgrade --install demo "${PROJECT_ROOT}/charts/demo" --namespace mtc-lab \
  --set-string "image=${NGINX_IMAGE}" \
  --set-string "configRevision=$(sha256sum "${PROJECT_ROOT}/charts/demo/templates/application.yaml" | cut -d' ' -f1)" \
  --wait --timeout 5m
kubectl apply -f "${PROJECT_ROOT}/manifests/gateway.yaml"
kubectl -n mtc-lab wait --for=condition=Accepted gateway/mtc-gateway --timeout=180s
kubectl -n mtc-lab wait --for=condition=Programmed gateway/mtc-gateway --timeout=180s

log 'Deploy Loki'
render "${PROJECT_ROOT}/manifests/loki.yaml" | kubectl apply -f -
kubectl -n mtc-observability rollout status statefulset/mtc-loki --timeout=5m

log 'Build and load the reproducible Fluentd image'
sudo bash "${PROJECT_ROOT}/scripts/build-fluentd.sh"
render "${PROJECT_ROOT}/manifests/fluentd.yaml" | kubectl apply -f -
kubectl -n mtc-observability rollout status daemonset/mtc-fluentd --timeout=5m

log "Install kube-prometheus-stack ${PROMETHEUS_CHART_VERSION}"
sudo python3 "${PROJECT_ROOT}/scripts/prefetch.py"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "${PROMETHEUS_CHART_VERSION}" --namespace mtc-observability \
  --values "${PROJECT_ROOT}/values/prometheus.yaml" --wait --timeout 10m
kubectl apply -f "${PROJECT_ROOT}/manifests/monitoring.yaml"
kubectl -n mtc-observability create configmap mtc-demo-dashboard \
  --from-file=mtc-demo.json="${PROJECT_ROOT}/dashboards/mtc-demo.json" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n mtc-observability label configmap mtc-demo-dashboard grafana_dashboard=1 --overwrite >/dev/null
log 'Deployment complete. Run make verify.'
