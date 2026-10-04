#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_command helm
require_command python3
for script in "${PROJECT_ROOT}"/scripts/*.sh; do bash -n "${script}"; done
python3 - "${PROJECT_ROOT}/scripts" <<'PY'
import ast
import sys
from pathlib import Path
for path in Path(sys.argv[1]).glob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
print('Python source syntax passed')
PY
helm lint "${PROJECT_ROOT}/charts/demo" --set-string "image=${NGINX_IMAGE}"
helm template demo "${PROJECT_ROOT}/charts/demo" --namespace mtc-lab \
  --set-string "image=${NGINX_IMAGE}" | python3 "${PROJECT_ROOT}/scripts/validate-yaml.py"
export MTC_NODE_NAME=validation-node
for manifest in "${PROJECT_ROOT}"/manifests/*.yaml; do
  render "${manifest}" | python3 "${PROJECT_ROOT}/scripts/validate-yaml.py"
done
python3 "${PROJECT_ROOT}/scripts/validate-yaml.py" <"${PROJECT_ROOT}/values/prometheus.yaml"
python3 "${PROJECT_ROOT}/scripts/validate-yaml.py" <"${PROJECT_ROOT}/values/envoy.yaml"
for workflow in "${PROJECT_ROOT}"/.github/workflows/*.yml; do
  [[ -e "${workflow}" ]] || continue
  python3 "${PROJECT_ROOT}/scripts/validate-yaml.py" <"${workflow}"
done
for manifest in "${PROJECT_ROOT}"/lab/*.yaml; do
  python3 "${PROJECT_ROOT}/scripts/validate-yaml.py" <"${manifest}"
done
python3 "${PROJECT_ROOT}/scripts/check-public.py"
log 'Shell, Python, Helm, YAML and public-file checks passed'
