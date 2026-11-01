# Observability for Azure Local

Metrics, logs, traces and alerts for the site, all inside the cluster. They keep working when the
link to Azure is down: every image comes from the connected registry and every store is a volume
in the cluster. On Azure, Azure Monitor does this job.

| Folder | What it installs |
| --- | --- |
| [opentelemetry-collector](./opentelemetry-collector/values.yaml) | The collector the app sends to: Service `otel-collector`, OTLP on 4317 (gRPC) and 4318 (HTTP). Traces go to Tempo, logs to Loki; Prometheus scrapes the metrics from it. |
| [kube-prometheus-stack](./kube-prometheus-stack/values.yaml) | Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter and the Prometheus operator |
| [loki](./loki/values.yaml) | Log store, one process, chunks and index on its volume |
| [tempo](./tempo/values.yaml) | Trace store, one process, blocks on its volume |
| [monitoring](./monitoring) | RabbitMQ and cert-manager scraping, the app's alerts, the Order Management dashboard |

The app's pods get `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4317`.

## Install

[provision-observability.ps1](../../../scripts/infra/azurelocal/provision-observability.ps1) installs
everything into namespace `observability`. `setup-platform.ps1 -Target AzureLocal` runs it after
Keycloak, with the `Observability` section of `scripts/settings.json`. It needs:

- The images in the connected registry: they're in [images.txt](../images.txt) and in the
  connected registry's list. Run `import-images.ps1` and `connected-registry.ps1` after a chart
  version changes.
- Keycloak with the `grafana` client (`keycloak.ps1`). A realm imported before that client
  existed needs `keycloak.ps1 -ReimportRealm`.

Each values file says how to install that chart by hand.

## Grafana

Open `https://<ingress address>/grafana`, the app's address with `/grafana`. A path rather than a
host name works on a site with only an IP address, and leaves the app's own rule on `/` alone. The
ingress serves it with the app's certificate, which cert-manager issues from the `site-ca`
ClusterIssuer and renews.

Sign-in goes through Keycloak only; the login form and basic auth are off. Users with the realm
role `Inventory.Manage` (group `oms-inventory-admins`) get Editor, everyone else in the realm gets
Viewer. The admin password is in Secret `observability/grafana-admin` and isn't used to sign in.

Data sources: Prometheus, Alertmanager, Loki and Tempo. A trace links to its logs and a log line
with a `trace_id` links to its trace. The **Order Management** dashboard shows orders per minute,
processing time, queue and dead-letter lengths, stock by SKU and products below their reorder
level.

To serve Grafana at another address, pass `-GrafanaOrigin` to `keycloak.ps1` and the same value as
`-GrafanaUrl` to `provision-observability.ps1`.

## Alerts

| Alert | Fires when |
| --- | --- |
| OmsMessageDeadLettered | A queue named `*.dead-letter` holds messages (`rabbitmq_detailed_queue_messages`) |
| OmsProcessorStalled | Orders have stayed in the `orders` queue for 15 minutes (`rabbitmq_detailed_queue_messages`) and `oms_orders_completed_total` didn't rise |
| OmsInventoryBelowReorder | `oms_inventory_below_reorder` is above 0 |
| CertificateRenewalOverdue | A cert-manager certificate is more than an hour past its renewal time and wasn't renewed (`certmanager_certificate_renewal_timestamp_seconds`) |
| CertManagerMetricsMissing | Prometheus gets nothing from cert-manager, so the alert above can't fire |

The chart adds the usual Kubernetes alerts. With `SmtpHost`, `SmtpFrom` and `AlertEmailTo` set,
Alertmanager emails warning and critical alerts. For a server that needs a password, create the
Secret first and set `SmtpUsername` and `SmtpPasswordSecret`:

```powershell
kubectl -n observability create secret generic smtp-auth --from-literal=password=<password>
```

Without an SMTP server, alerts show in Grafana under **Alerting** only.

## Retention and sizes

Set these in the `Observability` section of `scripts/settings.json` and run the step again:

| Setting | Default | |
| --- | --- | --- |
| `PrometheusRetention`, `PrometheusStorage` | `15d`, `10Gi` | Prometheus also deletes old data once it fills 90% of the volume |
| `LokiRetention`, `LokiStorage` | `168h`, `10Gi` | |
| `TempoRetention`, `TempoStorage` | `72h`, `10Gi` | |
| `StorageClassName` | empty | Empty uses the cluster's default storage class |

Retention changes apply on the next run. Sizes apply when a volume is created. To grow a volume
later, expand its claim, if the storage class allows it (`kubectl -n observability get pvc`, then
`kubectl -n observability edit pvc <name>`). Keep `LokiStorage` and `TempoStorage` at their first
values: Kubernetes doesn't let a StatefulSet's volume template change, so the next Helm upgrade
would fail.
