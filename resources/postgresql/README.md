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
  - **Microsoft Entra ID with workload identity:** becomes a password for the service's own role, or a client certificate (see [Signing in](#signing-in)). Generate and rotate the password on site, or bring it from [Key Vault](../key-vault/README.md) if it already lives in Azure.

## What you need to change

1. **Pick the sign-in method at startup** from configuration: an Entra token on Azure, a password on Azure Local. Use the same image on both targets.
2. **Create a database role for each service** on each target. On Azure, map the role to the service's managed identity. On Azure Local, give it a password.
3. **Store and rotate the passwords on Azure Local.** Keep them out of the image and the deployment files.
4. **Trust the site's certificate authority** in the app, so it can check the database server's certificate.
5. **Check your extensions.** Flexible server allows a [fixed list of extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions). The PostgreSQL images include the standard ones.
6. **Run PostgreSQL yourself.** You, or an operator, handle replicas, backups, upgrades and monitoring.

How flexible server maps to each alternative, and how the sample does each step: [CloudNativePG](./alternatives/cloudnative-pg.md), [PostgreSQL container](./alternatives/postgresql-container.md).

## Signing in

| | Azure (flexible server) | Azure Local (both alternatives) |
|---|---|---|
| Sign-in | [Microsoft Entra authentication](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication) only, password authentication disabled | Password (SCRAM-SHA-256) over TLS |
| What the application sends | An Entra access token, through the ordinary password field | The role's password |
| Stored secret | None | A password per role, generated on site and stored as a Kubernetes Secret; changed by a rotation script |
| In Npgsql | [`UsePeriodicPasswordProvider`](https://www.npgsql.org/doc/security.html) supplies a fresh token for new connections | The same hook supplies the password |

Password-free options on Azure Local exist but aren't used by the sample, which uses passwords for PostgreSQL as it does for SQL Server:

- **Client certificates** ([`cert` authentication](https://www.postgresql.org/docs/current/auth-cert.html)): CloudNativePG trusts a client CA you give it, and PostgreSQL maps the certificate's name to the role. cert-manager's CSI driver can give each pod a short-lived certificate named after its service account, renewed automatically, with no stored password. Npgsql takes the certificate files in place of a password.
- **PostgreSQL 18 [OAuth sign-in](https://www.postgresql.org/docs/current/auth-oauth.html)** with the site's identity provider: Npgsql doesn't support it yet ([npgsql/npgsql#6156](https://github.com/npgsql/npgsql/issues/6156)).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Same engine, so queries and data carry over. Server parameters, extensions and connection pooling are configured on the cluster, not through Azure. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available. The sample uses a password per role, stored as a Kubernetes Secret. Client certificates would remove the stored password. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You run the database. CloudNativePG gives you failover, synchronous replicas and point-in-time restore. The sample's backups stay in the same cluster, so copy them off site. A single container has none of these. |

**Data:** data in flexible server doesn't move by itself. Dump and restore it during a planned switch.

## Sample

The inventory service in the [Order Management sample](../../samples/OrderManagementApp/README.md) keeps products and stock in PostgreSQL. On Azure that's flexible server. On Azure Local it's CloudNativePG by default, or a single container. The app is the same in all three.
