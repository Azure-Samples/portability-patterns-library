# Azure Database for PostgreSQL → Azure Local

Azure Database for PostgreSQL flexible server isn't available on Azure Local. This guide shows what you can use instead, what stays the same, and what you change in your workload.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [CloudNativePG](./alternatives/cloudnative-pg.md) | `protocol-compatible` | Sample available | Open-source Kubernetes operator (Apache-2.0) that runs PostgreSQL in the cluster with replicas, automatic failover and continuous backups. Same engine, driver and SQL. |
| Azure Local | [PostgreSQL container](./alternatives/postgresql-container.md) | `protocol-compatible` | Sample available | The official PostgreSQL image, one instance on a persistent volume, no operator. Simpler to run, but no failover and no backups. |

## What carries over

- **The engine:** PostgreSQL, the same SQL and the same driver (Npgsql for .NET). Use the same major version on both targets.
- **The schema:** created by the same versioned migrations on both targets.
- **Business logic:** queries and transactions don't change, including row locks that keep concurrent updates consistent.
- **Least privilege:** each service signs in as its own database role with only the rights it needs, on both targets.
- **Encrypted, verified connections:** the server presents a certificate the client checks, from a public CA on Azure and from the site's CA on Azure Local.
- **Authentication model**, depending on how you connect to flexible server today:
  - **Password (PostgreSQL login):** stays a password.
  - **Microsoft Entra ID with workload identity:** becomes a password for the service's own role. Keep it outside the cluster, for example in [Key Vault](../key-vault/README.md), so it isn't the only copy. See [Signing in](#signing-in).

## What you need to change

1. **Choose the credential at startup** from configuration: an Entra access token on Azure, a password on Azure Local. Not with build flags or separate images.
2. **Create the database roles on each target.** On Azure, a role mapped to each service's managed identity. On Azure Local, a password role per service. A setup job that runs as the administrator keeps this in one place.
3. **Store and rotate the passwords** on Azure Local, and get them to the service without putting them in the image or the deployment definition.
4. **Trust the site's CA** in the client, so it verifies the in-cluster server's certificate.
5. **Check your extensions.** Flexible server allows a [listed set of extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions); the images ship the standard ones.
6. **Run and operate PostgreSQL** in the cluster: replicas, backups, upgrades and monitoring are yours, or the operator's.

How flexible server maps to each alternative, and how the sample does each step: [CloudNativePG](./alternatives/cloudnative-pg.md), [PostgreSQL container](./alternatives/postgresql-container.md).

## Signing in

| | Azure (flexible server) | Azure Local (both alternatives) |
|---|---|---|
| Sign-in | [Microsoft Entra authentication](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication) only, password authentication disabled | Password (SCRAM-SHA-256) over TLS |
| What the application sends | An Entra access token, through the ordinary password field | The role's password |
| Stored secret | None | A password per role, kept in Key Vault and synced into the cluster |
| In Npgsql | [`UsePeriodicPasswordProvider`](https://www.npgsql.org/doc/security.html) supplies a fresh token for new connections | The same hook supplies the password |

Password-free options on Azure Local exist but aren't used by the sample:

- **Client certificates** ([`cert` authentication](https://www.postgresql.org/docs/current/auth-cert.html)): short-lived certificates from cert-manager, no stored password. CloudNativePG supports them natively.
- **PostgreSQL 18 [OAuth sign-in](https://www.postgresql.org/docs/current/auth-oauth.html)** with the site's identity provider: Npgsql doesn't support it yet ([npgsql/npgsql#6156](https://github.com/npgsql/npgsql/issues/6156)).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Same engine, so queries and data carry over. Server parameters, extensions and connection pooling are configured on the cluster, not through Azure. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available. The sample uses a password per role, kept in Key Vault. Client certificates would remove the stored password. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You run the database. CloudNativePG provides failover, synchronous replicas and point-in-time restore, but the sample's backups go to an object store in the same cluster, so copy them off site. A single container has none of these. |

**Data:** data in flexible server doesn't move by itself. Dump and restore it during a planned switch.

## Sample

The inventory service in the [Order Management sample](../../samples/OrderManagementApp/README.md) keeps products and stock in PostgreSQL: flexible server on Azure, and on Azure Local CloudNativePG (the default, availability `high`) or a single container (availability `standard`). The application is the same in all three.
