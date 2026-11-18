#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_base
require_kind

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "Deleting Kind cluster '${CLUSTER_NAME}' and its node data."
  kind delete cluster --name "${CLUSTER_NAME}"
else
  log "Kind cluster '${CLUSTER_NAME}' is not present."
fi

if docker ps -a --format '{{.Names}}' | grep -qx "${GIT_CONTAINER}"; then
  log "Removing local git daemon container '${GIT_CONTAINER}'."
  docker rm -f "${GIT_CONTAINER}" >/dev/null
fi

state="${ROOT}/terraform/argocd/terraform.tfstate"
if [[ -f "${state}" ]]; then
  log "Removing Terraform state for the deleted cluster."
  rm -f "${state}" "${state}.backup"
fi

log "Cluster removed. Repository files were left in place."
log "Persistent volume data lived on the Kind node and was deleted with it."
