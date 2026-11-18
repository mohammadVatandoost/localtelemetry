#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-otel-platform}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
GIT_CONTAINER="${GIT_CONTAINER:-otel-platform-git}"
GIT_IMAGE="${GIT_IMAGE:-alpine/git:2.54.1}"
GIT_PORT="${GIT_PORT:-9418}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.6.1}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.18.1}"
REPO_URL="${REPO_URL:-https://github.com/mohammadVatandoost/localtelemetry}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  local cmd="$1"
  local why="$2"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    die "missing '${cmd}'. ${why}"
  fi
}

require_base() {
  need docker "Install Docker Engine. Kind runs Kubernetes inside Docker: https://docs.docker.com/engine/install/ubuntu/"
  need kubectl "Install kubectl 1.32 or newer: https://kubernetes.io/docs/tasks/tools/"
  need git "Git is required. Argo CD clones this repository from a local git daemon."
  need curl "curl is used by the telemetry scripts."
  need python3 "python3 updates the in-cluster git Service address."
}

require_kind() {
  need kind "Install kind 0.33.x so the pinned node image matches the release: https://kind.sigs.k8s.io/docs/user/quick-start/"
}

require_terraform() {
  need terraform "Install Terraform 1.5 or newer. It installs Argo CD: https://developer.hashicorp.com/terraform/install"
}

warn_optional_tools() {
  if ! command -v helm >/dev/null 2>&1; then
    warn "Helm is not installed. Argo CD renders the pinned charts, so Helm is optional unless you want to run 'helm template' locally."
  fi
  if ! command -v argocd >/dev/null 2>&1; then
    warn "The argocd CLI is not installed. Bootstrap uses kubectl. Install the CLI only if you want 'argocd app' commands."
  fi
}

warn_memory() {
  if [[ -r /proc/meminfo ]]; then
    local available_kb
    available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    if [[ -n "${available_kb}" && "${available_kb}" -lt 14680064 ]]; then
      warn "Less than 14 GiB of memory is available ($((available_kb / 1024)) MiB). The platform requests about 9 GiB plus three Kind nodes. Free memory before bootstrap if pods stay Pending."
    fi
  fi
}

use_cluster_context() {
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
}
