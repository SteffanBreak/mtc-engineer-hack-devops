#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[[ "${EUID}" -eq 0 ]] || fail 'Storage preparation requires sudo on the dedicated Ubuntu.'
[[ -e /var/lib/mtc-devops/managed ]] || fail 'Dedicated lab marker not found; refusing host changes.'
install -d -m 755 /var/lib/mtc-devops/storage
install -d -m 770 -o 10001 -g 10001 /var/lib/mtc-devops/storage/loki
install -d -m 770 -o 1000 -g 2000 /var/lib/mtc-devops/storage/prometheus
install -d -m 770 -o 472 -g 472 /var/lib/mtc-devops/storage/grafana
install -d -m 700 /var/lib/mtc-devops/storage/fluentd
