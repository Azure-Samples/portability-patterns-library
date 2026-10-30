# Application Insights and Log Analytics → Azure Local

Application Insights and the Log Analytics workspace behind it run in Azure. A workload on Azure Local that has to keep working while the site is cut off from Azure also needs its telemetry on site. This guide shows what you can use instead, what stays the same, and what you change in your workload.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana](./alternatives/grafana-stack.md) | `adapter-required` | Sample planned | Open-source stack run in the cluster: metrics, logs and traces stored on site, dashboards and alerts in Grafana. Grafana, Loki and Tempo are AGPL-3.0. |
| Azure Local | [OpenTelemetry Collector with Prometheus, Jaeger and OpenSearch](https://opentelemetry.io/docs/collector/) | — | Documentation available | Not evaluated by this project. An all Apache-2.0 stack for organizations that don't allow AGPL. |
| Azure Local | [Azure Monitor pipeline](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-overview) | — | Documentation available | Not evaluated by this project. Buffers telemetry on site and sends it to Azure Monitor when the link is up; analysis still happens in Azure. |

## What carries over

- **The instrumentation**, if the application uses [OpenTelemetry](https://opentelemetry.io/docs/languages/dotnet/): traces, metrics and logs, including the automatic instrumentation for ASP.NET Core, HTTP clients and SQL.
- **Trace context** across services and queues, through the W3C `traceparent` header.
- **Signals and names:** the same span names, metric names and log properties appear in both backends.
- **What you monitor:** the same service-level indicators and alert conditions, rewritten in the new query language.

## What you need to change

1. **Use OpenTelemetry in the application.** On Azure, the [Azure Monitor OpenTelemetry Distro](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable). If the application still uses the classic Application Insights SDK (`TelemetryClient`), move it to OpenTelemetry first.
2. **Choose the exporter at startup** from configuration: Azure Monitor when an Application Insights connection string is set, OTLP to a collector when an [`OTEL_EXPORTER_OTLP_ENDPOINT`](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/) is set. Not with build flags or separate images.
3. **Propagate trace context through the queue**, so one order shows as one trace from the API to the processor on both targets.
4. **Rebuild dashboards, alerts and queries.** Workbooks and KQL alert rules don't carry over. Grafana uses PromQL for metrics, LogQL for logs and TraceQL for traces.
5. **Run and operate the stack** in the cluster: storage, retention, upgrades and access control are yours to set up.

How Application Insights features map to the stack, and how the sample will use it: [OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana](./alternatives/grafana-stack.md).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Observability](https://learn.microsoft.com/azure/well-architected/operational-excellence/observability) | The signals carry over through OpenTelemetry, but KQL, workbooks, Application Map, Live Metrics, smart detection and availability tests don't. Grafana provides dashboards, alerting and a service graph built from traces. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | On Azure, the application can send telemetry with [Microsoft Entra authentication](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication) instead of the connection string's key. On Azure Local, the collector inside the cluster receives telemetry on a cluster-internal endpoint; protect it with network policies or mutual TLS. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You host, size, back up and scale the stack. Telemetry storage grows with retention, and the stack must stay up when the application has problems, which is when you need it. |

**Data:** telemetry already in Log Analytics stays there. The two backends don't share history.

**Licence:** Grafana, Loki and Tempo are licensed under AGPL-3.0, and some organizations don't allow AGPL software. Check your organization's open-source policy. Because the application only speaks OpenTelemetry to the collector, those organizations can use the Apache-2.0 alternative above, or [Grafana Enterprise](https://grafana.com/licensing/), without changing the application.

## Sample

Planned: the [Order Management sample](../../samples/OrderManagementApp/README.md) will send OpenTelemetry from the API, processor and inventory service, to Application Insights on Azure and to the on-site stack on Azure Local.
