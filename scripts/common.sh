#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/config/versions.env"
STATE_DIR="${PROJECT_ROOT}/.local"
prepare_state() { mkdir -p "${STATE_DIR}"; chmod 700 "${STATE_DIR}"; }

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null || fail "Required command is missing: $1"; }

require_cluster() {
  require_command kubectl
  kubectl get namespace mtc-lab >/dev/null 2>&1 || fail 'Expected mtc-lab namespace is missing. Run make deploy first.'
  [[ "$(kubectl get namespace mtc-lab -o jsonpath='{.metadata.labels.mtc-managed}')" == 'true' ]] || fail 'This cluster is not marked as the MTC lab.'
}

render() {
  python3 "${PROJECT_ROOT}/scripts/render.py" "$1"
}
