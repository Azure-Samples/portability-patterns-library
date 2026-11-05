# Monitoring for Azure Local

Metrics, logs, traces and alerts for the site, all inside the cluster, so they keep working when the
link to Azure is down. On Azure, Azure Monitor does this job.

| Folder | What it installs |
| --- | --- |
| [opentelemetry-collector](./opentelemetry-collector/values.yaml) | The collector the app sends OTLP to; traces go to Tempo, logs to Loki |
| [kube-prometheus-stack](./kube-prometheus-stack/values.yaml) | Prometheus, Alertmanager and Grafana |
| [loki](./loki/values.yaml) | Log store |
| [tempo](./tempo/values.yaml) | Trace store |
| [monitoring](./monitoring) | Scraping for RabbitMQ, PostgreSQL and cert-manager, the app's alerts and dashboard, network policies |

[provision-observability.ps1](../../../scripts/infra/azurelocal/provision-observability.ps1), the
`Observability` setup step, installs them into namespace `observability`.

## Grafana

Open `https://<app address>/grafana` and sign in through Keycloak. Only members of the AD group
`oms-operators` get in, since the logs carry customers' order details. The **Order Management**
dashboard shows orders per minute, processing time, queue lengths and stock.

## Alerts

| Alert | Fires when |
| --- | --- |
| OmsMessageDeadLettered | A dead-letter queue holds messages |
| OmsProcessorStalled | Orders have waited 15 minutes and none were completed |
| OmsInventoryBelowReorder | A product is at or below its reorder level |
| CertificateRenewalOverdue | A certificate is more than an hour past its renewal time |
| CertManagerMetricsMissing | Prometheus gets nothing from cert-manager |
| PostgresInstanceDown | A PostgreSQL instance has been down for 5 minutes |
| PostgresReplicationLagging | A replica is more than 5 minutes behind |
| PostgresWalArchivingFailing | Backups have been failing for 10 minutes |
| PostgresWalArchiveBacklog | Write-ahead log segments have waited 30 minutes to be archived |

To get them by email, set `SmtpHost`, `SmtpFrom` and `AlertEmailTo` in the `Observability` settings
(and `SmtpUsername` and `SmtpPasswordSecret` if the server needs a password). Otherwise they show in
Grafana under **Alerting**.

## Retention and sizes

| Setting | Default |
| --- | --- |
| `PrometheusRetention`, `PrometheusStorage` | `15d`, `5Gi` |
| `LokiRetention`, `LokiStorage` | `168h`, `5Gi` |
| `TempoRetention`, `TempoStorage` | `72h`, `5Gi` |

Sizes apply when a volume is created; keep `LokiStorage` and `TempoStorage` at their first values.