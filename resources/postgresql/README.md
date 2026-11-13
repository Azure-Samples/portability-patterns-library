# Azure Database for PostgreSQL → Azure Local

Azure Database for PostgreSQL flexible server isn't available on Azure Local. This guide describes the alternatives this project explored, what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [CloudNativePG](./alternatives/cloudnative-pg.md) | `protocol-compatible` | Sample available | Open-source Kubernetes operator (Apache-2.0) that runs PostgreSQL in the cluster with replicas, automatic failover and continuous backups. Same engine, driver and SQL. |
| Azure Local | [PostgreSQL container](./alternatives/postgresql-container.md) | `protocol-compatible` | Sample available | The official PostgreSQL image, one instance on a persistent volume, no operator. No failover and no backups. |

## What stayed the same in the sample

- **The engine:** PostgreSQL, the same SQL and the same driver (Npgsql for .NET). The sample uses the same major version on both targets.
- **The schema:** created by the same versioned migrations on both targets.
- **Business logic:** queries and transactions didn't change, including row locks that keep concurrent updates consistent.
- **Least privilege:** each service signs in as its own database role with only the rights it needs, on both targets.
- **Encrypted, verified connections:** the server presents a certificate the client checks, from a public CA on Azure and from the site's CA on Azure Local.
- **No password in the image or deployment files:** on Azure the sample signs in with Microsoft Entra ID and workload identity. On Azure Local that became a password for the service's own role, generated and rotated on site (see [Signing in](#signing-in)). An app that already signs in with a PostgreSQL password would keep it. The sample didn't test that path.

## What the sample needed to change

1. **The sign-in method chosen at startup** from configuration: an Entra token on Azure, a password on Azure Local. The images are the same on both targets.
2. **A database role for each service** on each target. On Azure the role is mapped to the service's managed identity. On Azure Local it has a password.
3. **Passwords generated, stored and rotated on Azure Local,** outside the image and the deployment files.
4. **The site's certificate authority trusted** by the app, so it can check the database server's certificate.
5. **PostgreSQL run in the cluster,** with the CloudNativePG operator by default, which handles replicas, failover and backups. Upgrades and monitoring are left to whoever runs the site.

The sample uses only standard extensions. Flexible server allows a [fixed list of extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions), so an app that uses others would need to check them on both targets.

How flexible server maps to each alternative, and the sample's code for each step: [CloudNativePG](./alternatives/cloudnative-pg.md), [PostgreSQL container](./alternatives/postgresql-container.md).

## Signing in

| | Azure (flexible server) | Azure Local (both alternatives) |
|---|---|---|
| Sign-in | [Microsoft Entra authentication](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication) only, password authentication disabled | Password (SCRAM-SHA-256) over TLS |
| What the application sends | An Entra access token, through the ordinary password field | The role's password |
| Stored secret | None | A password per role, generated on site and stored as a Kubernetes Secret; changed by a rotation script |
| In Npgsql | [`UsePeriodicPasswordProvider`](https://www.npgsql.org/doc/security.html) supplies a fresh token for new connections | The same hook supplies the password |

Password-free options on Azure Local exist but aren't used by the sample, which uses passwords for PostgreSQL as it does for SQL Server:

- **Client certificates** ([`cert` authentication](https://www.postgresql.org/docs/current/auth-cert.html)): CloudNativePG trusts a client CA it's given, and PostgreSQL maps the certificate's name to the role. cert-manager's CSI driver can give each pod a short-lived certificate named after its service account, renewed automatically, with no stored password. Npgsql takes the certificate files in place of a password.
- **PostgreSQL 18 [OAuth sign-in](https://www.postgresql.org/docs/current/auth-oauth.html)** with the site's identity provider: Npgsql doesn't support it yet ([npgsql/npgsql#6156](https://github.com/npgsql/npgsql/issues/6156)).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Same engine, so queries and data carry over. Server parameters, extensions and connection pooling are configured on the cluster, not through Azure. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available. The sample uses a password per role, stored as a Kubernetes Secret. Client certificates would remove the stored password. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The database is run on site. CloudNativePG provides failover, synchronous replicas and point-in-time restore. The sample's backups stay in the same cluster, so they'd need copying off site. A single container has none of these. |

**Data:** data in flexible server doesn't move by itself. It has to be dumped and restored during a planned switch.

## Sample

The inventory service in the [Order Management sample](../../samples/OrderManagementApp/README.md) keeps products and stock in PostgreSQL. On Azure that's flexible server. On Azure Local it's CloudNativePG by default, or a single container. The app is the same in all three.
