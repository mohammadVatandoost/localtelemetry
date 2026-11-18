# OpenTelemetry ingestion platform

GitOps deployment of a local OpenTelemetry pipeline on Kind. Argo CD reconciles this repository. Telemetry enters a gateway collector, crosses Kafka, and is indexed by Elasticsearch. Prometheus and Grafana watch the path.

The repository directory was empty, so this is the apps-of-apps layout. Nothing existing was replaced.

```text
Local Ubuntu
    |
    v
Kind cluster otel-platform (one node)
    |
    v
Argo CD  <---- git daemon on the Kind network
    |
    v
apps of apps
    |
    +-- Strimzi operator --> Kafka (one KRaft node)
    +-- ECK operator -----> Elasticsearch + Kibana
    +-- Prometheus + Grafana
    |
    v
Gateway collector --Kafka--> Backend collector --> Elasticsearch
         |                         |
         +---- internal metrics ---+----> Prometheus --> Grafana
```

Signals:

```text
OTLP logs, traces, metrics
        |
        v
Gateway collector (4317 gRPC, 4318 HTTP)
        |
        +-- otel-logs     --+
        +-- otel-traces   --+--> Kafka --> Backend collector
        +-- otel-metrics  --+         |
                                      v
                              logs-otel.otel-prod
                              traces-otel.otel-prod
                              metrics-otel.otel-prod
```

## Versions

| Piece | Version |
|---|---|
| kind node | Kubernetes 1.34.11, image built for kind 0.33.0 |
| Argo CD | 3.6.1, Helm chart argo-cd 10.18.1 |
| Strimzi | 1.3.1, Kafka 4.3.2, KRaft |
| ECK | 3.5.0 |
| Elasticsearch and Kibana | 9.4.3 |
| Collector contrib | 0.165.1 |
| Prometheus chart | 29.47.2 |
| Grafana chart | 14.5.0 |
| Elasticsearch exporter chart | 7.5.0 |
| local-path provisioner | 0.0.37 |

Kubernetes 1.34 is used because Strimzi 1.3 supports 1.32–1.37 and ECK 3.5 supports 1.32–1.36. Kind 0.33's default node is 1.37, which is outside the ECK window.

## Prerequisites

- Ubuntu with Docker Engine, kind 0.33.x, kubectl 1.32+, Terraform 1.5+, git, curl, and python3.
- About 10 GiB of free memory. Steady requests are about 5.8 GiB plus the Kind control plane. This machine should have that much free before you bootstrap. A host that is already using most of 32 GiB will leave pods Pending.
- Helm and the `argocd` CLI are optional. Terraform installs Argo CD. Argo CD renders the other charts. The scripts tell you when a required command is missing.

## Repository layout

```text
argocd/root-app.yaml                         root Application
argocd/applications/                         one Application per component
platform/namespaces/                         namespaces
platform/infrastructure/local-path/          Kind StorageClass
platform/infrastructure/strimzi/             operator values
platform/infrastructure/eck/                 operator values
platform/messaging/kafka/                    cluster, topics, metrics
platform/storage/                            Elasticsearch, Kibana, ILM
platform/telemetry/gateway/                  gateway collector
platform/telemetry/backend/                  backend collector
platform/telemetry/canary/                   trace and metric canary
platform/observability/                      Prometheus, Grafana, ES exporter
kind/cluster.yaml
terraform/argocd/                            Terraform install of Argo CD
scripts/                                     cluster and telemetry helpers
```

Extra Applications beyond the suggested tree are there because the cluster needs them: a StorageClass, namespaces, the Elasticsearch exporter, ILM, Grafana dashboard ConfigMaps, and the canary.

## Port mappings

Kind forwards these host ports to NodePorts on the single node.

| Host | NodePort | Service |
|---|---:|---|
| 8080 | 30080 | Argo CD HTTP |
| 3000 | 30300 | Grafana |
| 5601 | 30601 | Kibana HTTPS |
| 9200 | 30920 | Elasticsearch HTTPS |
| 4317 | 30317 | Gateway OTLP gRPC |
| 4318 | 30318 | Gateway OTLP HTTP |

Kafka is only available inside the cluster at `otel-kafka-bootstrap.kafka.svc:9092`. Prometheus is only available inside the cluster. Port-forward it when you want the UI:

```bash
kubectl -n observability port-forward svc/prometheus-server 9090:80
```

## Install

```bash
scripts/bootstrap.sh
```

That script is safe to run again. It creates the Kind cluster if needed, commits local manifest changes so Argo CD can see them, starts a git daemon on the Kind Docker network, installs Argo CD with Terraform, and applies `argocd/root-app.yaml`.

`scripts/install-argocd.sh` runs `terraform apply` in `terraform/argocd`. The release is the `argo-cd` chart 10.18.1 (Argo CD 3.6.1). State stays on this machine in `terraform/argocd/terraform.tfstate` and is not committed. `scripts/delete-cluster.sh` deletes that state with the cluster, so the next bootstrap installs Argo CD again.

The git daemon is plain `git://` and is only for this laptop. A later environment should point every Application `repoURL` at your real remote. Search for `git://git.argocd.svc.cluster.local/otel-platform`.

```bash
kubectl get applications -n argocd
kubectl get pods -A
```

Operators sync before custom resources only as an Argo CD sync-wave hint. Waves do not wait for health between Applications. Each Application retries, so a Kafka or Elasticsearch apply that lands before its CRDs exist is retried rather than left failed.

After you edit manifests, commit them and wait about a minute, or run `scripts/bootstrap.sh` again. Argo CD only sees commits.

## Access

Argo CD: http://localhost:8080

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

User `admin`.

Grafana: http://localhost:3000

The password is generated by `scripts/create-secrets.sh` and stored in `.secrets/grafana-admin.txt`. That directory is gitignored. User `admin`.

Kibana: https://localhost:5601

Elasticsearch: https://localhost:9200

ECK creates the password after Elasticsearch is healthy. User `elastic`.

```bash
kubectl -n telemetry get secret otel-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d; echo
```

Both UIs use a cluster-local certificate. Accept the browser warning, or trust the CA from `otel-es-http-certs-public`.

No password is stored in Git. Grafana's password is a Secret created at bootstrap. Elasticsearch's password and CA are Secrets created by ECK. Replacing that with an external secret store later means pointing the backend collector and the exporter at the new Secret names (`otel-es-elastic-user` key `elastic`, `otel-es-http-certs-public` key `ca.crt`).

## Send and check telemetry

```bash
scripts/send-telemetry.sh
scripts/verify-elasticsearch.sh
```

`verify-elasticsearch.sh` checks the three data streams. To look for the ids printed by the send script:

```bash
scripts/verify-elasticsearch.sh <log-id> <trace-id> <metric-id>
```

Collector metrics:

```bash
kubectl -n telemetry port-forward svc/gateway-collector 8888:8888
curl -s localhost:8888/metrics | head
```

Kafka messages are OTLP protobuf, so a console consumer prints binary. Use it only to see that records arrived:

```bash
kubectl -n kafka exec otel-dual-role-0 -- \
  bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic otel-logs --from-beginning --max-messages 1
```

The readable check is Elasticsearch.

```bash
kubectl get kafka -n kafka
kubectl get kafkatopic -n kafka
kubectl get elasticsearch,kibana -n telemetry
kubectl get pods -n telemetry
```

## Data streams

Collector 0.165.1 in `otel` mapping mode appends `.otel` to `data_stream.dataset` when routing is dynamic. The backend sets dataset `otel` and namespace `prod`, so the streams are:

```text
logs-otel.otel-prod
traces-otel.otel-prod
metrics-otel.otel-prod
```

Those names match the built-in Elasticsearch OTel templates (`logs-*.otel-*` and the same for traces and metrics). Static names such as `logs-otel-prod` would skip that suffix and miss the templates, so they are not used.

An ILM policy `otel-local` rolls each stream daily or at 1 GiB and deletes it after 3 days. Change `RETENTION_DAYS` on the `elasticsearch-ilm` CronJob to keep data longer. The job runs every 15 minutes and applies the policy again after the exporter creates a stream.

## Kafka persistence and consumer groups

One KRaft process is both broker and controller. Its log is a 5 GiB `local-path` volume. `deleteClaim: false` and the KafkaTopic resources keep the data if Argo CD prunes the cluster object. Replication factor and `min.insync.replicas` are 1. There is no second replica, so under-replicated partitions are not a durability signal here.

Topics `otel-logs`, `otel-traces`, and `otel-metrics` have one partition, 24 hour or 512 MiB retention, and `cleanup.policy=delete`. The gateway writes `otlp_proto`. The backend reads `otlp_proto` from the same topics. Auto topic creation is off.

The backend uses consumer group `otel-backend`. Offsets are committed after a successful pipeline (`message_marking.after: true`). A failed record is not committed and is retried with backoff, so a bad batch is not dropped to keep the partition moving. `initial_offset` is `earliest`, so the first start reads what is already in the topic. The queue uses an emptyDir file store: it survives a container restart and is lost if the pod is rescheduled. `block_on_overflow: true` makes the collector wait instead of dropping when the queue is full.

## Timestamps and SLOs

Logs use `ObservedTimestamp - Timestamp` at the gateway.

- SDKs usually set ObservedTimestamp when they emit the record. The gateway leaves that value alone.
- If ObservedTimestamp is zero, `transform/observe` sets it to the gateway clock. That is the observation boundary for records that were not already observed.
- The value is not network latency. It includes SDK buffering, send delay, and clock difference between the SDK host and the gateway.
- A missing timestamp or a negative duration is a data-quality failure. Those records are counted on `otel_log_timestamp_missing_total` and `otel_log_timestamp_negative_total` and are excluded from the latency ratio.

The log SLO is event-based: fraction of usable log events at or under 30 seconds, over 30 days, target 99.9%. The recording rule is `slo:logs_event_age:within_30s:ratio_30d`. Change the `30d` range and the `le="30"` bucket in `platform/observability/prometheus/values.yaml` to move the window or the threshold. The target gauge is `slo:logs_event_age:target`.

Traces and metrics do not use that timestamp delta. A CronJob sends one trace and one `otel.platform.canary` point per minute, then searches Elasticsearch. The canary id is only on that synthetic series. Do not scrape those points into Prometheus. Success within 60 seconds is a probe SLO, not a statement about every trace or metric point. Rules: `slo:traces_canary:within_objective:ratio_30d` and `slo:metrics_canary:within_objective:ratio_30d`.

One-hour ratios, collector export success, and Kafka lag are operational indicators. Elasticsearch indexing rate is not an ingestion SLO.

Prometheus keeps 30 days, capped at 8 GiB, on a 10 GiB volume. A quiet lab fits. Raise the volume before raising cardinality.

## Dashboards

Grafana folder **OpenTelemetry**:

1. Ingestion overview
2. Collector health
3. Kafka health
4. Elasticsearch health
5. Ingestion SLO

## Resource requests

Requests are what the scheduler uses. Limits are higher so a short burst does not kill the process, except Elasticsearch, whose limit equals its request so the JVM cannot grow without bound.

| Component | CPU request | Memory request | Memory limit | Note |
|---|---:|---:|---:|---|
| Argo CD, four processes | 225m | 512Mi | 1280Mi | Dex and notifications are not installed. ApplicationSet stays at 0 replicas |
| local-path provisioner | 20m | 32Mi | 128Mi | Required. Kind has no StorageClass |
| Strimzi operator | 100m | 384Mi | 512Mi | Chart default is 384Mi. 256Mi is too small for this JVM |
| Kafka broker | 250m | 768Mi | 1536Mi | Heap 384Mi |
| Topic and user operators | 100m | 256Mi | 512Mi | Needed for KafkaTopic resources |
| Kafka exporter | 25m | 64Mi | 128Mi | Consumer lag |
| ECK operator | 100m | 256Mi | 512Mi | |
| Elasticsearch | 500m | 2Gi | 2Gi | ECK sets the heap to about half of 2Gi |
| Kibana | 100m | 512Mi | 1Gi | |
| Gateway and backend | 200m | 256Mi | 512Mi | One replica each. Memory limiter at 200Mi |
| Prometheus | 100m | 512Mi | 1Gi | 30 day retention, 10Gi disk |
| Grafana | 50m | 128Mi | 256Mi | |
| Elasticsearch exporter, kube-state-metrics, node-exporter, pushgateway | 85m | 192Mi | 384Mi | |

Steady requests are about **1.9 CPU** and **5.8 GiB**. Kind also reserves 512Mi for kubelet and 512Mi for the system, and the control-plane pods need roughly another 1 GiB. Plan on 10 GiB free.

Collector replica count is `spec.replicas` on each Deployment. Kafka replica count is the node pool `replicas`, which must stay 1 unless you also raise topic replication. Elasticsearch node count is `nodeSets.count`.

Collector queues use emptyDir so a second replica does not share a ReadWriteOnce volume. Raise `replicas` only after giving each pod its own disk if you need the queue to survive reschedule.

## Troubleshooting

- Application `ComparisonError` or missing CRD: wait. The Application retries. `kubectl get applications -n argocd` should move to `Synced` / `Healthy`.
- Kafka or Elasticsearch stuck in `Progressing`: `kubectl describe kafka otel -n kafka` and `kubectl describe elasticsearch otel -n telemetry`. The usual cause on Kind is the StorageClass not being ready yet, or not enough memory.
- Collector not Ready: the health port returns 503 while Kafka or Elasticsearch is failing. Liveness is TCP, so the pod stays up and retries. `kubectl logs -n telemetry deploy/gateway-collector`.
- Empty Grafana panels: in Prometheus, look for `otelcol_receiver_accepted_log_records_total` and `otel_log_event_age_seconds_bucket`. Names follow collector 0.165.1 with Prometheus type and unit suffixes enabled.
- Elasticsearch rejects documents: `kubectl logs -n telemetry deploy/backend-collector`. Mapping mode is forced to `otel`. Streams appear after the first successful bulk request.
- Git changes never sync: they are uncommitted, or the git container was removed. Run `scripts/bootstrap.sh`.
- Pods Pending: `kubectl describe pod -n telemetry` will say memory. Free host memory or lower a request in the matching values file.

## Tear down

```bash
scripts/delete-cluster.sh
```

This deletes the Kind cluster, its disks, the git daemon container, and the local Terraform state for Argo CD. It does not delete this directory.

## Production overlay

Keep these manifests as the local profile. For another cluster, copy the Application specs and change:

- `repoURL` to the real Git remote
- StorageClass names
- replica counts, replication factor, and `min.insync.replicas`
- resource requests
- Kafka listener TLS
- how Grafana and Elasticsearch passwords are supplied

Do not point a shared cluster at the laptop git daemon.
