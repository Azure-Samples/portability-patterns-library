# CloudNativePG as an alternative to Azure Database for PostgreSQL

> **Draft.** The Order Management sample doesn't use it yet. The sample is planned.

[CloudNativePG](https://cloudnative-pg.io/docs/1.30/) is an open-source Kubernetes operator (Apache-2.0, a CNCF project) that runs PostgreSQL in the cluster. You describe a `Cluster` resource; the operator creates the instances, replication, failover, certificates and backups. It runs the same PostgreSQL engine as flexible server, so the application keeps its driver and SQL.

## Flexible server features in CloudNativePG

| Flexible server | CloudNativePG | Notes |
|---|---|---|
| Server | `Cluster` resource | You deploy and operate it. |
| Database and owner | Created at bootstrap (`app` database owned by user `app` by default) | More databases and roles are declared on the `Cluster` or with `Database` resources. |
| Compute and storage tiers | Pod CPU and memory, persistent volume size and storage class | |
| [High availability](https://cloudnative-pg.io/docs/1.30/replication) (zone-redundant standby) | `instances: 3`: one primary, streaming replicas, automatic failover | Spread instances over nodes. Azure Local has no availability zones. |
| Read replicas | The same replicas, through the `-ro` service | |
| [Automatic backups](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-backup-restore), point-in-time restore | [Backups](https://cloudnative-pg.io/docs/1.30/backup) to object storage with WAL archiving, or volume snapshots | Not set up by default. Choose a target that stays reachable when the site is offline. |
| Server parameters | `postgresql.parameters` on the `Cluster` | Some parameters are fixed by the operator. See [PostgreSQL configuration](https://cloudnative-pg.io/docs/1.30/postgresql_conf). |
| Built-in PgBouncer | `Pooler` resource | |
| [Extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions) allow-list | Whatever the PostgreSQL image contains | Standard contrib extensions are included. Others need a custom image. |
| Microsoft Entra authentication | [Client certificate authentication](https://cloudnative-pg.io/docs/1.30/ssl_connections) (`cert` in `pg_hba`) | See below. |
| Password authentication | Generated password in the `<cluster>-app` Secret | |
| Firewall rules, private endpoint | Kubernetes Services and network policies | The database is reachable inside the cluster only, unless you expose it. |
| Azure Monitor metrics | Prometheus metrics exported by each instance | |

## Signing in without a password

Flexible server accepts an Entra access token as the password. CloudNativePG has no equivalent token sign-in that .NET can use today, so the password-free option is a client certificate:

1. **A CA for database clients.** cert-manager, which the Azure Local cluster already runs, holds a [CA issuer](https://cert-manager.io/docs/configuration/ca/) used only for database clients. Keep it separate from the CA that signs ingress certificates, so no other certificate can sign in to the database.
2. **CloudNativePG trusts that CA.** The `Cluster` names it in `certificates.clientCASecret`, with a replication certificate from the same CA in `certificates.replicationTLSSecret`. See [Certificates](https://cloudnative-pg.io/docs/1.30/certificates).
3. **`pg_hba` requires a certificate.** A `hostssl` rule with the `cert` method for the application user. PostgreSQL maps the certificate's common name to the database user.
4. **Each workload gets a certificate.** A cert-manager `Certificate` with common name `app`, short-lived (for example 24 hours) and renewed automatically, stored in a Secret mounted into the pod.
5. **The application points Npgsql at the files:** `SSL Mode=VerifyFull`, `SSL Certificate`, `SSL Key`, and `Root Certificate` for the server CA in the `<cluster>-ca` Secret. A renewed certificate is used for new connections; open connections are unaffected.

What this gives compared with Entra ID: no stored password, and short-lived credentials renewed by the platform. What it doesn't give: authorization from a central directory. The database user is fixed by the certificate's common name, and whoever can read the certificate Secret can sign in, so restrict that Secret like any credential.

## How the Order Management sample will do it

Planned. The inventory service will store products and stock in PostgreSQL:

| Step | Plan |
|---|---|
| Same deployment definition on both targets | A portable PostgreSQL Resource Type. Each target's Recipe creates the database and returns host, port, database, user and how to sign in: an Entra token on Azure, certificate files on Azure Local. |
| Azure | Flexible server with Entra authentication only, the workload's managed identity mapped to a database role. |
| Azure Local | A CloudNativePG `Cluster`, client certificates from cert-manager, images from the in-cluster connected registry. |
| Application | One Npgsql connection factory that uses the token provider or the certificate files depending on configuration. |

## Not covered by the sample

The Recipe will be sample code. Before production, add:

- backups and a tested restore, to a target that stays reachable when the site is offline;
- enough nodes to spread three instances;
- monitoring and alerts on replication lag, failover and storage;
- a plan for PostgreSQL major version upgrades.

## References

- [CloudNativePG documentation](https://cloudnative-pg.io/docs/1.30/)
- [CloudNativePG certificates](https://cloudnative-pg.io/docs/1.30/certificates) and [client TLS connections](https://cloudnative-pg.io/docs/1.30/ssl_connections)
- [PostgreSQL certificate authentication](https://www.postgresql.org/docs/current/auth-cert.html)
- [Npgsql security and encryption](https://www.npgsql.org/doc/security.html)
- [Microsoft Entra authentication with flexible server](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [Connect with a managed identity to flexible server](https://learn.microsoft.com/azure/postgresql/flexible-server/how-to-connect-with-managed-identity)
- [Azure Well-Architected: Azure Database for PostgreSQL](https://learn.microsoft.com/azure/well-architected/service-guides/postgresql)
