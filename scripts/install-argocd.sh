#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

require_base
require_terraform
use_cluster_context

kubeconfig="${KUBECONFIG:-${HOME}/.kube/config}"
kubeconfig="${kubeconfig%%:*}"

state="${ROOT}/terraform/argocd/terraform.tfstate"
if [[ -f "${state}" ]]; then
  if ! kubectl -n argocd get secret -l "owner=helm,name=argocd" >/dev/null 2>&1; then
    log "This cluster has no Argo CD Helm release. Clearing Terraform state from the previous cluster."
    rm -f "${state}" "${state}.backup"
  fi
fi

log "Installing Argo CD ${ARGOCD_VERSION} with Terraform (Helm chart ${ARGOCD_CHART_VERSION})."
terraform -chdir="${ROOT}/terraform/argocd" init -input=false
terraform -chdir="${ROOT}/terraform/argocd" apply -input=false -auto-approve \
  -var="kubeconfig=${kubeconfig}" \
  -var="kube_context=${KUBE_CONTEXT}"

log "Argo CD is up. HTTP is on NodePort 30080 (host port 8080)."
