#!/bin/sh
set -eu
gateway="${GATEWAY_URL:-http://gateway-collector.telemetry.svc:4318}"
es="${ES_URL:-https://otel-es-http.telemetry.svc:9200}"
push="${PUSHGATEWAY_URL:-http://pushgateway.observability.svc.cluster.local:9091}"
trace_limit="${TRACE_OBJECTIVE_SECONDS:-60}"
metric_limit="${METRIC_OBJECTIVE_SECONDS:-60}"
auth="elastic:${ELASTIC_PASSWORD}"

hex() {
  n="$1"
  out=""
  while :; do
    out="${out}$(printf '%04x' "${RANDOM:-0}")"
    if [ "${#out}" -ge "${n}" ]; then
      break
    fi
  done
  printf '%s' "${out}" | sed "s/^\(.\{${n}\}\).*/\1/"
}

now_nano() {
  printf '%s000000000' "$(date +%s)"
}

post_otlp() {
  path="$1"
  body="$2"
  curl -fsS -H 'Content-Type: application/json' --data-binary "${body}" "${gateway}${path}" >/dev/null
}

count_docs() {
  stream="$1"
  query="$2"
  curl -sS --cacert /tls/ca.crt -u "${auth}" \
    -H 'Content-Type: application/json' \
    "${es}/${stream}/_count" \
    -d "{\"query\":{\"query_string\":{\"query\":\"${query}\"}}}" || true
}

wait_for() {
  stream="$1"
  query="$2"
  deadline="$3"
  while :; do
    body="$(count_docs "${stream}" "${query}")"
    if printf '%s' "${body}" | grep -q '"count":[1-9]'; then
      return 0
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      return 1
    fi
    sleep 2
  done
}

push_result() {
  signal="$1"
  success="$2"
  latency="$3"
  within="$4"
  stamp="$5"
  {
    printf '# TYPE otel_canary_delivery_success gauge\n'
    printf 'otel_canary_delivery_success %s\n' "${success}"
    printf '# TYPE otel_canary_e2e_latency_seconds gauge\n'
    printf 'otel_canary_e2e_latency_seconds %s\n' "${latency}"
    printf '# TYPE otel_canary_within_objective gauge\n'
    printf 'otel_canary_within_objective %s\n' "${within}"
    printf '# TYPE otel_canary_last_success_timestamp_seconds gauge\n'
    printf 'otel_canary_last_success_timestamp_seconds %s\n' "${stamp}"
  } | curl -fsS --data-binary @- "${push}/metrics/job/otel_canary/signal/${signal}"
}

run_signal() {
  signal="$1"
  limit="$2"
  start="$(date +%s)"
  cid="$(hex 16)"
  nano="$(now_nano)"
  end_nano="$(printf '%s000000100' "${start}")"

  if [ "${signal}" = "traces" ]; then
    trace_id="$(hex 32)"
    span_id="$(hex 16)"
    post_otlp /v1/traces "{
      \"resourceSpans\": [{
        \"resource\": {\"attributes\": [{\"key\": \"service.name\", \"value\": {\"stringValue\": \"otel-platform-canary\"}}]},
        \"scopeSpans\": [{
          \"scope\": {\"name\": \"canary\"},
          \"spans\": [{
            \"traceId\": \"${trace_id}\",
            \"spanId\": \"${span_id}\",
            \"name\": \"ingestion-canary\",
            \"kind\": 1,
            \"startTimeUnixNano\": \"${nano}\",
            \"endTimeUnixNano\": \"${end_nano}\",
            \"attributes\": [
              {\"key\": \"canary.id\", \"value\": {\"stringValue\": \"${cid}\"}},
              {\"key\": \"canary.signal\", \"value\": {\"stringValue\": \"traces\"}}
            ]
          }]
        }]
      }]
    }"
    stream="traces-otel.otel-prod"
  else
    post_otlp /v1/metrics "{
      \"resourceMetrics\": [{
        \"resource\": {\"attributes\": [{\"key\": \"service.name\", \"value\": {\"stringValue\": \"otel-platform-canary\"}}]},
        \"scopeMetrics\": [{
          \"scope\": {\"name\": \"canary\"},
          \"metrics\": [{
            \"name\": \"otel.platform.canary\",
            \"gauge\": {\"dataPoints\": [{
              \"asDouble\": 1,
              \"timeUnixNano\": \"${nano}\",
              \"attributes\": [
                {\"key\": \"canary.id\", \"value\": {\"stringValue\": \"${cid}\"}},
                {\"key\": \"canary.signal\", \"value\": {\"stringValue\": \"metrics\"}}
              ]
            }]}
          }]
        }]
      }]
    }"
    stream="metrics-otel.otel-prod"
  fi

  deadline="$((start + limit))"
  if wait_for "${stream}" "${cid}" "${deadline}"; then
    latency="$(( $(date +%s) - start ))"
    success=1
    if [ "${latency}" -le "${limit}" ]; then
      within=1
    else
      within=0
    fi
    stamp="$(date +%s)"
  else
    latency="${limit}"
    success=0
    within=0
    stamp=0
  fi
  echo "${signal} id=${cid} success=${success} latency=${latency}s within=${within}"
  push_result "${signal}" "${success}" "${latency}" "${within}" "${stamp}"
}

log_id="$(hex 16)"
log_nano="$(now_nano)"
post_otlp /v1/logs "{
  \"resourceLogs\": [{
    \"resource\": {\"attributes\": [{\"key\": \"service.name\", \"value\": {\"stringValue\": \"otel-platform-canary\"}}]},
    \"scopeLogs\": [{
      \"scope\": {\"name\": \"canary\"},
      \"logRecords\": [{
        \"timeUnixNano\": \"${log_nano}\",
        \"severityText\": \"INFO\",
        \"body\": {\"stringValue\": \"ingestion-canary ${log_id}\"},
        \"attributes\": [{\"key\": \"canary.id\", \"value\": {\"stringValue\": \"${log_id}\"}}]
      }]
    }]
  }]
}"
echo "log id=${log_id}"

run_signal traces "${trace_limit}"
run_signal metrics "${metric_limit}"
