#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ "${EUID}" -eq 0 ]] || fail 'Build requires sudo on the dedicated Ubuntu.'
[[ -e /var/lib/mtc-devops/managed ]] || fail 'Dedicated lab marker not found.'
MTC_BUILD_HASH="$(sha256sum "${PROJECT_ROOT}/images/fluentd/Dockerfile" | cut -d' ' -f1)"
MTC_IMAGE_NAME="docker.io/library/${FLUENTD_IMAGE}"
if [[ -e /var/lib/mtc-devops/fluentd-build.sha256 ]] && \
   [[ "$(cat /var/lib/mtc-devops/fluentd-build.sha256)" == "${MTC_BUILD_HASH}" ]] && \
   ctr --namespace k8s.io images list -q | awk -v name="${MTC_IMAGE_NAME}" '$0 == name {found=1} END {exit !found}'; then
  log 'The exact Fluentd build is already loaded in containerd'
  exit 0
fi

install -d -m 755 /etc/docker
cat >/var/lib/mtc-devops/docker-builder.json <<'EOF'
{"iptables":false,"ip6tables":false,"bridge":"none"}
EOF
if [[ -e /etc/docker/daemon.json ]] && ! cmp -s /etc/docker/daemon.json /var/lib/mtc-devops/docker-builder.json; then
  fail 'An unexpected Docker daemon configuration exists; it was not overwritten.'
fi
install -m 644 /var/lib/mtc-devops/docker-builder.json /etc/docker/daemon.json
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends "docker.io=${DOCKER_DEB_VERSION}" "docker-buildx=${BUILDX_DEB_VERSION}"
systemctl enable --now docker
docker build --network host --progress plain --tag "${FLUENTD_IMAGE}" "${PROJECT_ROOT}/images/fluentd"
docker save "${FLUENTD_IMAGE}" --output /var/lib/mtc-devops/fluentd-image.tar
ctr --namespace k8s.io images import /var/lib/mtc-devops/fluentd-image.tar
printf '%s\n' "${MTC_BUILD_HASH}" >/var/lib/mtc-devops/fluentd-build.sha256
log 'Fluentd image is available to kubelet locally; no participant registry is required'
