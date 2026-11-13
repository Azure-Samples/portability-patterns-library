# Application Insights and Log Analytics → Azure Local

Application Insights stores its data in a Log Analytics workspace. Both run in Azure. A workload on Azure Local that has to keep working while the site has no or limited connectivity to Azure also needs its telemetry on site. This guide describes the alternatives this project explored, what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana](./alternatives/grafana-stack.md) | `adapter-required` | Sample available | Open-source stack run in the cluster: metrics, logs and traces stored on site, dashboards and alerts in Grafana. Grafana, Loki and Tempo are AGPL-3.0. |
| Azure Local | [OpenTelemetry Collector with Prometheus, Jaeger and OpenSearch](https://opentelemetry.io/docs/collector/) | — | Documentation available | Not evaluated by this project. An all Apache-2.0 stack for organizations that don't allow AGPL. |
| Azure Local | [Azure Monitor pipeline](https://learn.microsoft.com/azure/azure-monitor/data-collection/pipeline-overview) | — | Documentation available | Not evaluated by this project. Buffers telemetry on site and sends it to Azure Monitor when the link is up; analysis still happens in Azure. |

## What stayed the same in the sample

- **The instrumentation:** the sample uses [OpenTelemetry](https://opentelemetry.io/docs/languages/dotnet/) on both targets, for traces, metrics and logs, including the automatic instrumentation for ASP.NET Core, HTTP clients and SQL.
- **Trace context** across services and queues, through the W3C `traceparent` header.
- **Signals and names:** the same span names, metric names and log properties appear in both backends.
- **What the sample monitors:** the same conditions raise alerts on both targets, written in each backend's query language.

## What the sample needed to change

1. **OpenTelemetry in every service.** On Azure, the sample sends it to Azure Monitor through [Azure Monitor's OpenTelemetry support](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable). An app that still uses the classic Application Insights SDK would have to move to OpenTelemetry first.
2. **The destination chosen at startup** from configuration: Azure Monitor on Azure, an OpenTelemetry Collector ([`OTEL_EXPORTER_OTLP_ENDPOINT`](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/)) on Azure Local. The images are the same on both targets.
3. **Traces kept connected across the queue,** so one order shows as one trace from the API to the processor and the inventory service.
4. **Alerts rebuilt.** Workbooks and KQL alert rules don't carry over. On Azure Local the sample uses Prometheus alert rules; Grafana uses PromQL for metrics, LogQL for logs and TraceQL for traces.
5. **The stack run in the cluster.** The sample installs it from Helm charts. Storage, retention, upgrades and access control are left to whoever runs the site.

How Application Insights features map to the stack, and the sample's code for each step: [OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana](./alternatives/grafana-stack.md).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Observability](https://learn.microsoft.com/azure/well-architected/operational-excellence/observability) | The signals carry over through OpenTelemetry, but KQL, workbooks, Application Map, Live Metrics, smart detection and availability tests don't. Grafana provides dashboards, alerting and a service graph built from traces. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | On Azure, the sample sends telemetry with [Microsoft Entra authentication](https://learn.microsoft.com/azure/azure-monitor/app/azure-ad-authentication) instead of the connection string's key. On Azure Local, the collector receives telemetry on a cluster-internal endpoint without sign-in. The sample's network policy accepts it only from inside the cluster; mutual TLS is another option. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The stack is hosted, sized, backed up and scaled on site. Telemetry storage grows with retention, and the stack has to stay up when the application has problems, which is when it's needed. |

**Data:** telemetry already in Log Analytics stays there. The two backends don't share history.

**Licence:** Grafana, Loki and Tempo are licensed under AGPL-3.0, and some organizations don't allow AGPL software. Because the sample's services only speak OpenTelemetry to the collector, an organization that doesn't allow AGPL could use the Apache-2.0 alternative above, or [Grafana Enterprise](https://grafana.com/licensing/), without changing the application.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) sends OpenTelemetry from the API, processor and inventory service: to Application Insights on Azure, and to the on-site stack on Azure Local, with equivalent alerts on both. [OpenTelemetry Collector with Prometheus, Loki, Tempo and Grafana](./alternatives/grafana-stack.md#how-the-order-management-sample-does-it) links the code for each change above.
