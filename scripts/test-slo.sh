#!/usr/bin/env bash
# Send a known log mix through the gateway and check the SLI the gateway records.
#
# Usable logs: 8 at age 0 and 2 at age 90s. The within-30s ratio is 8/10 = 0.8.
# One log has no timestamp and one has a timestamp in the future. Those two are
# the invalid ratio 2/12 and are not part of the latency ratio.
# A trace and a metric go through the same gateway so the path is not logs-only.
set -euo pipefail

endpoint="${OTLP_HTTP_ENDPOINT:-http://127.0.0.1:4318}"
context="${KUBE_CONTEXT:-kind-otel-platform}"
within_n=8
slow_n=2
missing_n=1
negative_n=1
usable_n=$((within_n + slow_n))
total_n=$((usable_n + missing_n + negative_n))

if ! command -v curl >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "error: curl, kubectl, and python3 are required." >&2
  exit 1
fi

prom() {
  local query="$1"
  local encoded
  encoded="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "${query}")"
  kubectl --context "${context}" exec -n observability deploy/prometheus-server -c prometheus-server -- \
    wget -qO- "http://127.0.0.1:9090/api/v1/query?query=${encoded}"
}

# Print the scalar of a sum() query. An empty result is 0.
scalar() {
  prom "$1" | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("data",{}).get("result",[])
print(r[0]["value"][1] if r else "0")'
}

now="$(date +%s)"
now_nano="${now}000000000"
slow_nano="$((now - 90))000000000"
future_nano="$((now + 300))000000000"

records=""
add_record() {
  local time_nano="$1" observed_nano="${2:-}" body="$3"
  local observed=""
  if [[ -n "${observed_nano}" ]]; then
    observed="\"observedTimeUnixNano\":\"${observed_nano}\","
  fi
  if [[ -n "${records}" ]]; then
    records+=","
  fi
  records+="{\"timeUnixNano\":\"${time_nano}\",${observed}\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"${body}\"},\"attributes\":[{\"key\":\"slo.test\",\"value\":{\"stringValue\":\"gateway\"}}]}"
}

i=0
while ((i < within_n)); do
  add_record "${now_nano}" "${now_nano}" "slo within ${i}"
  i=$((i + 1))
done
i=0
while ((i < slow_n)); do
  add_record "${slow_nano}" "${now_nano}" "slo slow ${i}"
  i=$((i + 1))
done
add_record "0" "" "slo missing"
add_record "${future_nano}" "${now_nano}" "slo negative"

before_count="$(scalar 'sum(otel_log_event_age_seconds_count{job="otel-gateway-slo"})')"
before_within="$(scalar 'sum(otel_log_event_age_seconds_bucket{le="30.0",job="otel-gateway-slo"})')"
before_logs="$(scalar 'sum(otelcol_receiver_accepted_log_records_total{job="otel-gateway"})')"
before_spans="$(scalar 'sum(otelcol_receiver_accepted_spans_total{job="otel-gateway"})')"
before_metrics="$(scalar 'sum(otelcol_receiver_accepted_metric_points_total{job="otel-gateway"})')"

echo "Sending ${total_n} logs, 1 span, and 1 metric to ${endpoint}"
curl -fsS -H 'Content-Type: application/json' "${endpoint}/v1/logs" --data-binary @- >/dev/null <<EOF
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"slo-test"}}]},"scopeLogs":[{"scope":{"name":"slo-test"},"logRecords":[${records}]}]}]}
EOF
curl -fsS -H 'Content-Type: application/json' "${endpoint}/v1/traces" --data-binary @- >/dev/null <<EOF
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"slo-test"}}]},"scopeSpans":[{"scope":{"name":"slo-test"},"spans":[{"traceId":"0123456789abcdef0123456789abcdef","spanId":"0123456789abcdef","name":"slo-test","kind":1,"startTimeUnixNano":"${now_nano}","endTimeUnixNano":"${now_nano}"}]}]}]}
EOF
curl -fsS -H 'Content-Type: application/json' "${endpoint}/v1/metrics" --data-binary @- >/dev/null <<EOF
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"slo-test"}}]},"scopeMetrics":[{"scope":{"name":"slo-test"},"metrics":[{"name":"slo.test","gauge":{"dataPoints":[{"asDouble":1,"timeUnixNano":"${now_nano}"}]}}]}]}]}
EOF

echo "Waiting for the gateway SLO scrape (up to 90s)"
deadline=$((SECONDS + 90))
after_count="${before_count}"
while ((SECONDS < deadline)); do
  after_count="$(scalar 'sum(otel_log_event_age_seconds_count{job="otel-gateway-slo"})')"
  python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) + float(sys.argv[3]) else 1)' \
    "${after_count}" "${before_count}" "${usable_n}" && break
  sleep 5
done

after_within="$(scalar 'sum(otel_log_event_age_seconds_bucket{le="30.0",job="otel-gateway-slo"})')"
after_logs="$(scalar 'sum(otelcol_receiver_accepted_log_records_total{job="otel-gateway"})')"
after_spans="$(scalar 'sum(otelcol_receiver_accepted_spans_total{job="otel-gateway"})')"
after_metrics="$(scalar 'sum(otelcol_receiver_accepted_metric_points_total{job="otel-gateway"})')"

# The quality counters appear on the first bad event. Match whichever suffix the exporter used.
missing_query="$(prom '{__name__=~"otel_log_timestamp_missing.*",job="otel-gateway-slo"}' | python3 -c 'import json,sys
d=json.load(sys.stdin)
names=sorted({r["metric"]["__name__"] for r in d.get("data",{}).get("result",[])})
print(names[0] if names else "")')"
negative_query="$(prom '{__name__=~"otel_log_timestamp_negative.*",job="otel-gateway-slo"}' | python3 -c 'import json,sys
d=json.load(sys.stdin)
names=sorted({r["metric"]["__name__"] for r in d.get("data",{}).get("result",[])})
print(names[0] if names else "")')"
if [[ -n "${missing_query}" ]]; then
  missing_now="$(scalar "sum(${missing_query}{job=\"otel-gateway-slo\"})")"
else
  missing_now=0
fi
if [[ -n "${negative_query}" ]]; then
  negative_now="$(scalar "sum(${negative_query}{job=\"otel-gateway-slo\"})")"
else
  negative_now=0
fi

python3 - <<PY
before_count = float("${before_count}")
after_count = float("${after_count}")
before_within = float("${before_within}")
after_within = float("${after_within}")
before_logs = float("${before_logs}")
after_logs = float("${after_logs}")
before_spans = float("${before_spans}")
after_spans = float("${after_spans}")
before_metrics = float("${before_metrics}")
after_metrics = float("${after_metrics}")
missing_now = float("${missing_now}")
negative_now = float("${negative_now}")
usable = ${usable_n}
within = ${within_n}
slow = ${slow_n}
total = ${total_n}

d_count = after_count - before_count
d_within = after_within - before_within
d_slow = d_count - d_within
d_logs = after_logs - before_logs
d_spans = after_spans - before_spans
d_metrics = after_metrics - before_metrics
ratio = (d_within / d_count) if d_count else 0
expected = within / (within + slow)

print(f"gateway accepted logs delta:    {d_logs:.0f} (sent {total})")
print(f"gateway accepted spans delta:   {d_spans:.0f} (sent 1)")
print(f"gateway accepted metrics delta: {d_metrics:.0f} (sent 1)")
print(f"usable logs in histogram:       {d_count:.0f} (expected at least {usable})")
print(f"within 30s:                     {d_within:.0f} (expected at least {within})")
print(f"over 30s:                       {d_slow:.0f} (expected {slow})")
print(f"within-30s ratio:               {ratio:.3f} (expected {expected:.3f})")
print(f"missing-timestamp counter:      {missing_now:.0f} on ${missing_query:-absent} (expected at least ${missing_n})")
print(f"negative-age counter:           {negative_now:.0f} on ${negative_query:-absent} (expected at least ${negative_n})")
print(f"invalid ratio of this batch:    {( ${missing_n} + ${negative_n} ) / total:.3f}")

ok = (
    d_logs >= total and d_spans >= 1 and d_metrics >= 1
    and d_count >= usable and d_within >= within and abs(d_slow - slow) < 0.5
    and missing_now >= ${missing_n} and negative_now >= ${negative_n}
    and abs(ratio - expected) <= 0.05
)
raise SystemExit(0 if ok else 1)
PY
