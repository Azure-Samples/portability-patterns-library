# OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana as an alternative to Application Insights

> **Draft.** The Order Management sample doesn't use it yet. The sample is planned.

On Azure Local, an on-site stack stores and shows the telemetry that Application Insights and Log Analytics hold on Azure. Every part runs in the cluster, so it keeps working when the site is cut off from Azure:

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
| Azure Monitor OpenTelemetry Distro | OpenTelemetry SDK with the OTLP exporter | Same instrumentation libraries. |
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

## How the Order Management sample will do it

Planned:

| Step | Plan |
|---|---|
| Instrumentation | The API, processor and inventory service use OpenTelemetry for ASP.NET Core, HTTP, SQL and the queue clients. |
| Choosing the exporter | At startup from configuration: Azure Monitor on Azure, OTLP on Azure Local. Same images. |
| One trace per order | Trace context travels in the queue message headers, from the API through the processor to the inventory service. |
| Alerts on site | Dead-lettered orders, a stalled processor, low stock and expiring certificates. |
| Images | Mirrored into the in-cluster connected registry, like every other image on Azure Local. |

## Not covered by the sample

The stack will be sample code. Before production, add:

- high availability for each component, or accept gaps in telemetry during restarts;
- retention and storage sized for your volume;
- backups of dashboards and alert rules, ideally kept as code;
- access control in Grafana through the site's identity provider.

## References

- [OpenTelemetry for .NET](https://opentelemetry.io/docs/languages/dotnet/)
- [OpenTelemetry SDK environment variables](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)
- [Enable Azure Monitor OpenTelemetry](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable)
- [Grafana licensing](https://grafana.com/licensing/)
- [Azure Managed Grafana](https://learn.microsoft.com/azure/managed-grafana/overview), if you also want Grafana on Azure
