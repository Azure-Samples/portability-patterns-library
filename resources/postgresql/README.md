# Azure Database for PostgreSQL → Azure Local

Azure Database for PostgreSQL flexible server isn't available on Azure Local. This guide shows what you can use instead, what stays the same, and what you change in your workload.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [CloudNativePG](./alternatives/cloudnativepg.md) | `protocol-compatible` | Sample planned | Open-source Kubernetes operator that runs PostgreSQL in the cluster, with replicas, failover and backups. Same engine and driver; sign-in, operations and backups change. |

## What carries over

- **The engine:** PostgreSQL, same major version, same SQL, same driver (Npgsql for .NET).
- **Schema and data:** move with `pg_dump` and `pg_restore`, or CloudNativePG's [database import](https://cloudnative-pg.io/docs/1.30/database_import).
- **Business logic:** queries, transactions and migrations don't change.
- **Authentication model**, depending on how you connect to flexible server today:
  - **Password (PostgreSQL login):** stays a password. CloudNativePG generates one for the application user and keeps it in a Kubernetes Secret. Still a stored secret.
  - **Microsoft Entra ID with workload identity:** stays password-free, but the mechanism changes. The application presents a short-lived client certificate instead of an Entra access token. See [Authentication](#authentication) below.

## What you need to change

1. **Build the connection per target from configuration.** On Azure, an access token as the password. On Azure Local, client certificate files. Keep the rest of the connection string the same.
2. **Switch the credential:** Entra token, client certificate or password, matching how you authenticate today (see above).
3. **Create the application's database user** on each target. On Azure, a role mapped to the workload's managed identity. On Azure Local, the user CloudNativePG creates as owner of the application database.
4. **Check your extensions.** Flexible server allows a [listed set of extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions). The CloudNativePG image ships the standard PostgreSQL ones; anything else needs a custom image.
5. **Run and operate PostgreSQL** in the cluster: replicas, backups, upgrades and monitoring are yours to set up.

How CloudNativePG maps to flexible server, and how the sample will use it: [CloudNativePG as an alternative](./alternatives/cloudnativepg.md).

## Authentication

| | Azure (flexible server) | Azure Local (CloudNativePG) |
|---|---|---|
| Recommended | [Microsoft Entra authentication](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication) with workload identity, password authentication disabled | [Client certificate](https://www.postgresql.org/docs/current/auth-cert.html) issued by cert-manager |
| What the application sends | An Entra access token as the password | A certificate whose common name is the database user |
| Stored secret | None | None: cert-manager issues short-lived certificates and renews them |
| In Npgsql | [`UsePeriodicPasswordProvider`](https://www.npgsql.org/doc/security.html) fetches and refreshes the token | `SSL Certificate`, `SSL Key` and `Root Certificate` connection string parameters point at the mounted files |

PostgreSQL 18 also supports [OAuth sign-in](https://www.postgresql.org/docs/current/auth-oauth.html), which would let the application use the same federated token flow as the RabbitMQ alternative for Service Bus, with Keycloak as the issuer. It isn't usable yet: Npgsql doesn't support it ([npgsql/npgsql#6156](https://github.com/npgsql/npgsql/issues/6156)), and the Keycloak token validator for PostgreSQL is experimental.

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Same engine, so queries and data carry over. Flexible server features such as its extension allow-list, server parameters set through Azure and built-in connection pooling (PgBouncer) are configured differently in CloudNativePG. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available. The password-free equivalent is a client certificate from cert-manager, not a token, so the application builds its connection differently on each target. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You host, patch, back up and scale the database. CloudNativePG provides replicas and automatic failover, but backups need object storage or volume snapshots, which you set up. |

**Data:** data in flexible server doesn't move by itself. Dump and restore it, or import it with CloudNativePG, during a planned switch.

## Sample

Planned: the inventory service in the [Order Management sample](../../samples/OrderManagementApp/README.md) will store products and stock in PostgreSQL, on flexible server on Azure and CloudNativePG on Azure Local.
