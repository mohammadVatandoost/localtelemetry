#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_base
require_kind
require_terraform
warn_optional_tools
warn_memory

"${ROOT}/scripts/create-cluster.sh"

if ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "Initializing a local git repository."
  git -C "${ROOT}" init
fi

log "Recording the working tree so Argo CD can clone it."
git -C "${ROOT}" add -A
if ! git -C "${ROOT}" rev-parse --verify HEAD >/dev/null 2>&1 || ! git -C "${ROOT}" diff --cached --quiet; then
  git -C "${ROOT}" -c user.email="otel-platform@local" -c user.name="otel-platform" \
    commit -m "Update local OpenTelemetry platform manifests"
else
  log "No manifest changes to commit."
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${GIT_CONTAINER}"; then
  log "Replacing the existing git daemon so it is attached to the Kind network."
  docker rm -f "${GIT_CONTAINER}" >/dev/null
fi

log "Starting git daemon (${GIT_IMAGE}) on the Kind network."
docker run -d --name "${GIT_CONTAINER}" --network kind \
  -v "${ROOT}:/git/otel-platform" \
  "${GIT_IMAGE}" \
  daemon --reuseaddr --export-all --base-path=/git --listen=0.0.0.0 \
  --port="${GIT_PORT}" --informative-errors --verbose /git >/dev/null

git_ip="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "${GIT_CONTAINER}")"
if [[ -z "${git_ip}" ]]; then
  die "git daemon has no IP on the kind network."
fi
log "Git daemon is at ${git_ip}:${GIT_PORT}."

"${ROOT}/scripts/install-argocd.sh"

log "Publishing the git daemon inside the cluster as git.argocd."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: git
  namespace: argocd
  labels:
    app.kubernetes.io/name: git
    app.kubernetes.io/part-of: otel-platform
spec:
  ports:
    - name: git
      port: ${GIT_PORT}
      targetPort: ${GIT_PORT}
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: git
  namespace: argocd
  labels:
    app.kubernetes.io/name: git
    app.kubernetes.io/part-of: otel-platform
subsets:
  - addresses:
      - ip: ${git_ip}
    ports:
      - name: git
        port: ${GIT_PORT}
        protocol: TCP
EOF

"${ROOT}/scripts/create-secrets.sh"

log "Applying the root application."
kubectl apply -f "${ROOT}/argocd/root-app.yaml"

cat <<EOF

Bootstrap submitted the root application.
Argo CD will keep retrying until operators, CRDs, and workloads are ready.

Watch progress:
  kubectl get applications -n argocd
  kubectl get pods -A

Argo CD:  http://localhost:8080
  user: admin
  password:
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

Grafana password file: ${ROOT}/.secrets/grafana-admin.txt
Repository URL used by applications: ${REPO_URL}

After you change manifests, commit them (or re-run this script) so the git daemon serves the new commit.
EOF
