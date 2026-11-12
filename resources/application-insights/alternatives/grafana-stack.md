# OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana as an alternative to Application Insights

On Azure Local, an on-site stack stores and shows the telemetry that Application Insights and Log Analytics hold on Azure. Every part runs in the cluster, and its images come from the in-cluster registry, so it keeps working when the site is cut off from Azure:

| Part | Role | Licence |
|---|---|---|
| [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) | Receives OTLP from the application and routes each signal | Apache-2.0 |
| [Prometheus](https://prometheus.io/docs/introduction/overview/) with [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) | Metrics and alert notifications | Apache-2.0 |
| [Loki](https://grafana.com/docs/loki/latest/) | Logs | AGPL-3.0 |
| [Tempo](https://grafana.com/docs/tempo/latest/) | Traces | AGPL-3.0 |
| [Grafana](https://grafana.com/docs/grafana/latest/) | Dashboards, queries, alert rules | AGPL-3.0 |

## Application Insights features in the stack

| Application Insights / Log Analytics | On-site stack | Notes |
|---|---|---|
| Connection string | Collector endpoint in `OTEL_EXPORTER_OTLP_ENDPOINT` | |
| Azure Monitor OpenTelemetry exporter or Distro | OpenTelemetry SDK with the OTLP exporter | Same instrumentation libraries. |
| Requests, dependencies (traces) | Traces in Tempo | |
| Custom metrics, performance counters | Metrics in Prometheus | |
| Traces and exceptions (logs) | Logs in Loki, linked to traces by trace ID | |
| Log Analytics workspace, retention | Storage and retention set per component | Loki and Tempo keep data on persistent volumes or object storage. |
| KQL | PromQL, LogQL, TraceQL | Queries are rewritten. |
| Workbooks, dashboards | Grafana dashboards | |
| Alert rules, action groups | Grafana or Prometheus alert rules, Alertmanager receivers | Notifications need a reachable channel on site, such as email or a webhook. |
| Application Map | Service graph generated from traces in Tempo | |
| Live Metrics, smart detection, availability tests | No built-in equivalent | |
| Microsoft Entra authentication for ingestion | Cluster-internal endpoint, network policies, optionally mutual TLS | |
| Azure RBAC on the workspace | Grafana users and teams, signed in through the site's identity provider | Grafana supports OpenID Connect, so it can use Keycloak. |

## How the Order Management sample does it

| Step | In the sample |
|---|---|
| Instrumentation | [TelemetryExtensions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Diagnostics/TelemetryExtensions.cs): traces, metrics and logs for the API, processor and inventory service, including HTTP, SQL Server and Npgsql |
| Choosing the exporter | The same file, at startup: Azure Monitor when `APPLICATIONINSIGHTS_CONNECTION_STRING` is set, OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. Each target's Recipe Pack sets one of them, so the images are the same. |
| Signing in to Application Insights | Local authentication is off; each service sends with its own managed identity and the Monitoring Metrics Publisher role ([platform-resources.bicep](../../../samples/OrderManagementApp/infra/azure/platform-resources.bicep)) |
| One trace per order | The RabbitMQ client and the Service Bus SDK propagate the W3C trace context in the message's properties; [TelemetryExtensions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Diagnostics/TelemetryExtensions.cs) subscribes to their spans, so one order is one trace from the API through the queue to the processor and the inventory service |
| Business metrics | [OrderMetrics.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Diagnostics/OrderMetrics.cs): orders placed and completed, processing time, products below their reorder level |
| The stack on site | [provision-observability.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/provision-observability.ps1) installs the collector, kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki and Tempo from Helm charts with the [values in the sample](../../../samples/OrderManagementApp/infra/azurelocal/observability/README.md). Loki and Tempo run as single processes on persistent volumes. |
| Grafana access | Signs in through Keycloak only. Only the realm role `Operations.Monitor` (directory group `oms-operators`) gets in, as Editor, because logs include customer and order IDs; no one else gets an account. |
| Alerts | Azure: a dead-letter alert from the Service Bus Recipe, and log alerts for a stalled processor and low stock. Azure Local: [Prometheus rules](../../../samples/OrderManagementApp/infra/azurelocal/observability/monitoring/alerts.yaml) for dead-lettered messages, a stalled processor, low stock, overdue certificate renewals, and PostgreSQL instances that are down, lagging or no longer archiving, sent by email through Alertmanager when SMTP is configured. |

## Not covered by the sample

The sample's setup is for demonstration. Depending on your workload's requirements, a production deployment might also need:

- high availability for each component, or accept gaps in telemetry during restarts;
- retention and storage sized for your volume (the sample keeps metrics 15 days, logs 7 days and traces 3 days);
- backups of dashboards and alert rules, ideally kept as code;
- pinned chart and image versions that you upgrade deliberately.

## References

- [OpenTelemetry for .NET](https://opentelemetry.io/docs/languages/dotnet/)
- [OpenTelemetry SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [Enable Azure Monitor OpenTelemetry](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable)
- [Grafana licensing](https://grafana.com/licensing/)
- [Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/overview), if you also want Grafana on Azure
