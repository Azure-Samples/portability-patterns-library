# Order Management App: design

The app shows how an app written for Azure runs unchanged on Azure Local, and keeps working when the
site loses its link to Azure. This page describes the resources on each platform, the production
patterns each one follows, and what's still missing. It also covers the next scope: inventory on
PostgreSQL, Key Vault for the site's database credentials, and observability.

Status: **Built** is in `main` and tested on both platforms. **Planned** is the next scope.

## Architecture

Users sign in through Entra ID on Azure, or Keycloak backed by Active Directory on Azure Local.

```mermaid
flowchart LR
    user(["User"])
    admin(["Inventory admin"])
    api["API"]
    queue[["Queue"]]
    processor["Processor"]
    inventory["Inventory service<br/>(planned)"]
    storage[("Object storage<br/>order archive")]
    sql[("SQL<br/>orders")]
    postgres[("PostgreSQL<br/>products and stock<br/>(planned)")]
    otel["Telemetry<br/>Application Insights on Azure<br/>Grafana stack on Azure Local<br/>(planned)"]

    user -- "1. place order" --> api
    api -- "2. queue order" --> queue
    queue -- "3. deliver" --> processor
    processor -- "4. reserve stock" --> inventory
    processor -- "5. archive" --> storage
    processor -- "6. record result" --> sql
    user -. "see products and stock" .-> api
    admin -. "restock" .-> api
    api -. "direct call" .-> inventory
    inventory --> postgres
    api -. "my orders" .-> sql
    api & processor & inventory -. "traces, metrics, logs" .-> otel
```

- **Placing an order (solid, numbered):** the API prices the order from the inventory service's
  prices and queues it; stock is reserved later, by the processor. Placing an order keeps working
  while the processor or the inventory service is down. The order is recorded as "Processed", or
  as "Rejected: out of stock" (planned).
- **Products, stock and orders (dotted):** direct calls, not queued: the page waits for the
  answer, and the inventory admin sees the new stock straight away. Only users in the inventory
  admin group can restock (planned).
- **Telemetry (dotted):** each service sends traces, metrics and logs to what the platform
  provides (planned).

## Orders and stock (planned)

How the order flow stays correct once stock is reserved. The inventory build is written and tested
locally, but isn't in `main` yet.

| Concern | Design | In the inventory build |
|---|---|---|
| Two processor pods reserving the same product | One transaction per order. It locks the order's product rows, in SKU order so two orders can't deadlock, and reserves every line or none. Concurrent orders can't oversell. | ✅ |
| The same order delivered twice | The reservation row is keyed by order ID and claimed first, in the same transaction. A redelivered or concurrent call for that order gets the recorded result and takes no more stock. | ✅ |
| Order status | There's no SQL row until the processor records "Processed" or "Rejected: out of stock". Until then the page shows the order as "Submitted" and keeps checking it: every 2 seconds at first, backing off to every 30 seconds, for up to an hour. | ✅ |
| Inventory down vs out of stock | Out of stock rejects the order straight away. Inventory down is retried, not rejected: the processor backs off (1 s up to 30 s) for about 5 minutes, then hands the message back to the queue. With 10 deliveries, an order rides out an outage of about 50 minutes before it's dead-lettered. | ✅ |
| Order dead-lettered after its stock was reserved | On the order's last delivery, the processor releases its stock before the queue dead-letters it. Releasing is idempotent. A released order can be reserved again, for example when it's replayed from the dead-letter queue. If the release itself fails, the processor logs the order for releasing by hand. | ✅ |
| Inventory service down | The API keeps the last product list it fetched, for up to an hour. While inventory is down, it shows that list, with a notice saying how old the stock is, and prices new orders from it. The orders queue and complete once inventory is back. After a failed call, the API uses the list straight away for 15 seconds, so users don't each wait for a timeout. An API pod that started during the outage has no list, so for it, products and new orders are unavailable until inventory is back. | ✅ |

## Resources

| Resource | Azure | Azure Local | Status |
|---|---|---|---|
| Cluster | AKS, 2 nodes | AKS enabled by Arc: 1 control plane and 2 worker nodes | Built |
| Images and Recipes | Azure Container Registry | ACR connected registry inside the cluster, synced from ACR | Built |
| HTTPS address | Managed NGINX ingress, Let's Encrypt certificate | NGINX ingress on the Arc load balancer, site CA certificate renewed by cert-manager | Built |
| User sign-in | Entra ID | Keycloak (PostgreSQL behind it), federated to Active Directory | Built |
| Queue | Service Bus Standard | RabbitMQ container | Built |
| SQL | Azure SQL Database S0 | SQL Server 2022 container | Built |
| Object storage | Blob Storage, LRS | Azurite container (emulator) | Built |
| API, processor | Containers on the cluster | Same images, same app definition | Built |
| Inventory service | Container on the cluster | Same image, same app definition | Planned |
| PostgreSQL | Azure Database for PostgreSQL Flexible Server | PostgreSQL container | Planned |
| Secrets | None needed: workload identity everywhere | Key Vault, synced into the cluster by the Secret Store extension | Planned |
| Observability | Application Insights | OpenTelemetry Collector, Prometheus with Alertmanager, Loki, Tempo, Grafana | Planned |

## Production patterns by resource

✅ in place · ❌ missing · ➖ not applicable

### App (API, processor)

| Pattern | Status |
|---|---|
| Interfaces separate from implementations, dependency injection | ✅ |
| Repositories for SQL and storage; adapters for each broker and identity provider | ✅ |
| Processing a message twice is safe (SQL `MERGE`, archive overwritten) | ✅ |
| Health probes, CPU and memory limits | ✅ |
| Runs as a non-root user | ✅ |
| Images deployed by digest | ✅ |
| Multiple replicas, disruption budget | ❌ one replica each |
| Retries placing an order while the queue is down | ❌ returns an error instead |

### Identity

| Pattern | Azure | Azure Local |
|---|---|---|
| Users sign in through the organisation's directory | ✅ Entra ID | ✅ Keycloak backed by Active Directory |
| Services sign in with their own identity, no stored secret | ✅ for all services | ✅ queue only |
| Services call each other with their own token, never the user's (API and processor to inventory) | ❌ planned: Entra workload identity, app roles on the inventory app | ❌ planned: Keycloak token, client roles on the inventory client |
| Services get only the access they need | ✅ queue and storage<br/>❌ SQL: the app's identity is the server's administrator | ❌ SQL: the app signs in as `sa` |
| Keycloak's AD account limited to reading the app's OU | ➖ | ✅ |
| Directory connection encrypted | ➖ | ✅ LDAPS |
| Sign-in service runs more than one replica | ➖ managed by Microsoft | ❌ one Keycloak, one database |
| Secrets stored outside the cluster | ➖ no secrets | ❌ only in the cluster (planned: Key Vault) |

### Queue

| Pattern | Azure (Service Bus) | Azure Local (RabbitMQ) |
|---|---|---|
| Failed messages dead-lettered after 10 deliveries | ✅ | ✅ |
| Messages survive a restart | ✅ | ✅ persistent volume |
| Only identity-based sign-in | ✅ local auth disabled | ❌ the app uses its identity, but a password user stays for the management UI |
| Encrypted connection | ✅ TLS 1.2 | ❌ |
| Survives a node or zone failure | ❌ needs Premium | ❌ single node |

### SQL

| Pattern | Azure (Azure SQL) | Azure Local (SQL Server) |
|---|---|---|
| Data survives a restart | ✅ | ✅ persistent volume |
| Backups | ✅ automatic | ❌ |
| Password-free sign-in | ✅ Entra only | ❌ password |
| App gets only the access it needs | ❌ server administrator | ❌ `sa` |
| Encrypted connection, certificate checked | ✅ | ❌ certificate not checked |
| Private network access | ❌ public endpoint | ➖ in-cluster only |
| Survives a failure | ❌ no zone redundancy | ❌ single instance |
| Licensed for production | ✅ | ❌ Developer edition |

### Object storage

| Pattern | Azure (Blob Storage) | Azure Local (Azurite) |
|---|---|---|
| Password-free sign-in, no shared keys | ✅ | ❌ well-known emulator key |
| No public access, HTTPS only | ✅ | ❌ plain HTTP inside the cluster |
| Data survives a restart | ✅ | ❌ |
| Soft delete or versioning | ❌ | ❌ |
| Survives a failure | ❌ LRS | ❌ |
| Supported for production | ✅ | ❌ emulator, to be replaced |

### Ingress and certificates

| Pattern | Azure | Azure Local |
|---|---|---|
| HTTPS for users | ✅ | ✅ |
| Certificates renewed automatically | ✅ Let's Encrypt | ✅ cert-manager, offline |
| Certificates from the organisation's CA | ➖ public CA | ❌ site CA created by the setup |
| CA key backed up | ➖ | ❌ |

### Cluster

| Pattern | Azure (AKS) | Azure Local (AKS enabled by Arc) |
|---|---|---|
| Cluster admin access through an Entra group | ✅ | ✅ |
| Local accounts disabled | ✅ | ❌ |
| Images served from inside the site | ➖ | ✅ connected registry, works offline |
| Network policies between services | ❌ | ❌ (Calico engine is on) |
| More than one control plane node | ➖ managed | ❌ one |
| Availability zones | ❌ | ➖ |
| Automatic upgrades | ❌ | ❌ |
| Fixed image versions for SQL Server and RabbitMQ | ❌ floating tags | ❌ floating tags |

### Observability

| Pattern | Azure | Azure Local |
|---|---|---|
| Traces, metrics and logs from the app | ❌ planned | ❌ planned |
| Dashboards and alerts | ❌ planned | ❌ planned |
## Planned scope

1. **Inventory on PostgreSQL.** A separate inventory service owns products and stock. Azure: Flexible
   Server with workload identity. Azure Local: PostgreSQL container on a persistent volume. A second
   group, inventory admins, restocks through the app.
2. **Key Vault for the Azure Local database credentials.** The app gets its own least-privilege
   database users for SQL and PostgreSQL, instead of `sa` and the admin account. Their passwords
   live in Key Vault and the Secret Store extension syncs them into the cluster, so they keep
   working offline. Azure needs none: it uses workload identity.
3. **Observability.** The app sends OpenTelemetry to a collector the platform provides. Azure:
   Application Insights. Azure Local: an on-site stack, with alerts on dead-lettered orders, a
   stalled processor, low stock and expiring certificates.

## Open decisions

- **Key Vault on Azure Local:** the Secret Store extension signs in with Arc workload identity,
  which is in preview and can only be enabled when the cluster is created. Enabling it changes the
  cluster's token issuer, which Keycloak uses to accept the app's tokens; that needs testing. The
  extension also installs its own cert-manager, next to the one the connected registry runs.
- **SQL Server licence:** Developer edition for the sample; production needs Standard or Enterprise.
- **High availability:** replicas and clustering for each service, and which SQL Server option keeps
  working offline.
- **Object storage on Azure Local:** which supported store replaces Azurite.
