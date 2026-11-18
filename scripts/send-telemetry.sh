#!/usr/bin/env bash
# Send one log, one span, and one metric to the gateway OTLP HTTP endpoint.
set -euo pipefail

endpoint="${OTLP_HTTP_ENDPOINT:-http://127.0.0.1:4318}"

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required." >&2
  exit 1
fi

hex() {
  local n="$1" out=""
  while ((${#out} < n)); do
    out+=$(printf '%04x' "${RANDOM}")
  done
  printf '%s' "${out:0:n}"
}

now_nano="$(date +%s)000000000"
end_nano="$(date +%s)000000100"
log_id="$(hex 16)"
trace_id="$(hex 32)"
span_id="$(hex 16)"
metric_id="$(hex 16)"

echo "log canary.id=${log_id}"
echo "trace canary.id=${trace_id}"
echo "metric canary.id=${metric_id}"

curl -fsS -H 'Content-Type: application/json' "${endpoint}/v1/logs" --data-binary @- >/dev/null <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otel-platform-manual"}}]},"scopeLogs":[{"scope":{"name":"manual"},"logRecords":[{"timeUnixNano":"${now_nano}","severityText":"INFO","body":{"stringValue":"manual log ${log_id}"},"attributes":[{"key":"canary.id","value":{"stringValue":"${log_id}"}}]}]}]}]}
EOF

curl -fsS -H 'Content-Type: application/json' "${endpoint}/v1/traces" --data-binary @- >/dev/null <<EOF
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otel-platform-manual"}}]},"scopeSpans":[{"scope":{"name":"manual"},"spans":[{"traceId":"${trace_id}","spanId":"${span_id}","name":"manual-span","kind":1,"startTimeUnixNano":"${now_nano}","endTimeUnixNano":"${end_nano}","attributes":[{"key":"canary.id","value":{"stringValue":"${trace_id}"}}]}]}]}]}
EOF

curl -fsS -H 'Content-Type: application/json' "${endpoint}/v1/metrics" --data-binary @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"otel-platform-manual"}}]},"scopeMetrics":[{"scope":{"name":"manual"},"metrics":[{"name":"otel.platform.canary","gauge":{"dataPoints":[{"asDouble":1,"timeUnixNano":"${now_nano}","attributes":[{"key":"canary.id","value":{"stringValue":"${metric_id}"}},{"key":"canary.signal","value":{"stringValue":"metrics"}}]}]}}]}]}]}
EOF

echo "Accepted by the gateway at ${endpoint}."
echo "Search Elasticsearch for those canary.id values after a few seconds."
