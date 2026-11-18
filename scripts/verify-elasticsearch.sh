#!/usr/bin/env bash
# Check that logs, traces, and metrics data streams exist and contain documents.
# Optional arguments are canary.id values to search for, in order: log trace metric.
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "error: kubectl and curl are required." >&2
  exit 1
fi

context="${KUBE_CONTEXT:-kind-otel-platform}"
namespace="${ES_NAMESPACE:-telemetry}"
es_url="${ES_URL:-https://127.0.0.1:9200}"

password="$(kubectl --context "${context}" -n "${namespace}" get secret otel-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)"
if [[ -z "${password}" ]]; then
  echo "error: Elasticsearch password secret is empty. The Elasticsearch resource may still be starting." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
kubectl --context "${context}" -n "${namespace}" get secret otel-es-http-certs-public -o jsonpath='{.data.ca\.crt}' | base64 -d > "${tmpdir}/ca.crt"

query() {
  local path="$1"
  local data="${2:-}"
  if [[ -n "${data}" ]]; then
    curl -fsS --cacert "${tmpdir}/ca.crt" -u "elastic:${password}" -H 'Content-Type: application/json' "${es_url}${path}" -d "${data}"
  else
    curl -fsS --cacert "${tmpdir}/ca.crt" -u "elastic:${password}" "${es_url}${path}"
  fi
  printf '\n'
}

echo "Cluster health:"
query /_cluster/health

fail=0
check_stream() {
  local stream="$1"
  local needle="${2:-}"
  local body
  if [[ -n "${needle}" ]]; then
    body="$(query "/${stream}/_count" "{\"query\":{\"query_string\":{\"query\":\"${needle}\"}}}")"
    echo "${stream} matching ${needle}: ${body}"
  else
    body="$(query "/${stream}/_count")"
    echo "${stream}: ${body}"
  fi
  if ! printf '%s' "${body}" | grep -q '"count":[1-9]'; then
    echo "missing documents in ${stream}" >&2
    fail=1
  fi
}

check_stream logs-otel.otel-prod "${1:-}"
check_stream traces-otel.otel-prod "${2:-}"
check_stream metrics-otel.otel-prod "${3:-}"

if [[ "${fail}" -ne 0 ]]; then
  echo "One or more signals are not searchable yet. Data stream names follow the collector 0.165.0 otel mapping: <type>-otel.otel-prod." >&2
  exit 1
fi

echo "Logs, traces, and metrics are searchable."
