#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_base
use_cluster_context

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
mkdir -p "${ROOT}/.secrets"
chmod 700 "${ROOT}/.secrets"
secret_file="${ROOT}/.secrets/grafana-admin.txt"

if kubectl -n observability get secret grafana-admin >/dev/null 2>&1; then
  log "Grafana admin secret already exists. Leaving it unchanged."
  if [[ ! -s "${secret_file}" ]]; then
    pass="$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
    printf '%s\n' "${pass}" > "${secret_file}"
    chmod 600 "${secret_file}"
  fi
else
  pass="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
  printf '%s\n' "${pass}" > "${secret_file}"
  chmod 600 "${secret_file}"
  kubectl -n observability create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${pass}"
  log "Created Grafana admin secret. Password saved to .secrets/grafana-admin.txt (not committed)."
fi

cat <<'EOF'

Elasticsearch credentials are created by ECK after the Elasticsearch resource is healthy.
Retrieve them with:

  kubectl -n telemetry get secret otel-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d; echo

Do not copy that password into Git.
EOF
