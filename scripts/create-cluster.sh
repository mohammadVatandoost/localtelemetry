#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_base
require_kind
warn_memory

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "Kind cluster '${CLUSTER_NAME}' already exists."
  use_cluster_context
  kubectl cluster-info
  exit 0
fi

log "Creating Kind cluster '${CLUSTER_NAME}'."
kind create cluster --config "${ROOT}/kind/cluster.yaml" --name "${CLUSTER_NAME}"
use_cluster_context
kubectl cluster-info
log "Cluster is ready. Context: ${KUBE_CONTEXT}"
