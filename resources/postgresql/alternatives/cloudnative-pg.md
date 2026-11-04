# CloudNativePG as an alternative to Azure Database for PostgreSQL

[CloudNativePG](https://cloudnative-pg.io/docs/1.30/) is an open-source Kubernetes operator (Apache-2.0, a CNCF project) that runs PostgreSQL in the cluster. You describe a `Cluster` resource; the operator creates the instances, replication, failover and certificates, and with its [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/) the backups. It runs the same PostgreSQL engine as flexible server, so the application keeps its driver and SQL.

## Flexible server features in CloudNativePG

| Flexible server | CloudNativePG | Notes |
|---|---|---|
| Server | `Cluster` resource | The operator, installed once per cluster, runs it. |
| Database and owner | Created at bootstrap | More roles are created by your setup job or declared on the `Cluster`. |
| Compute and storage tiers | Pod CPU and memory, persistent volume size and storage class | |
| High availability with a standby | Several instances: one primary, streaming replicas, [automatic failover](https://cloudnative-pg.io/docs/1.30/replication) | Spread instances over nodes. Azure Local has no availability zones. |
| Zero data loss on failover | Synchronous replication | A commit waits until a replica has it. |
| Connection endpoint | The `-rw` Service, which follows the primary through a failover | `-ro` for replicas. |
| [Automatic backups, point-in-time restore](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-backup-restore) | Write-ahead log archived continuously, base backups on a schedule, to an S3-compatible store | Choose a store that stays reachable when the site is offline. |
| TLS with a public certificate | TLS with a certificate from your CA through cert-manager, reloaded on renewal | |
| Microsoft Entra authentication | Password roles, or [client certificates](https://cloudnative-pg.io/docs/1.30/ssl_connections) | |
| Server parameters | `postgresql.parameters` on the `Cluster` | Some are fixed by the operator. See [PostgreSQL configuration](https://cloudnative-pg.io/docs/1.30/postgresql_conf). |
| Built-in PgBouncer | `Pooler` resource | |
| [Extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions) allow-list | Whatever the image contains | Standard contrib extensions are included. |
| Azure Monitor metrics | Prometheus metrics from each instance | |

## How the Order Management sample does it

The sample uses CloudNativePG when its `Availability` setting is `high`, the default. The inventory service reaches it like flexible server on Azure:

```text
Inventory service  ──►  NpgsqlDataSource with a password provider
                               │  credential chosen at startup
                ┌──────────────┴──────────────┐
      Entra access token               Role password
   (flexible server, Azure)       (CloudNativePG, Azure Local)
```

| Step | In the sample |
|---|---|
| Same deployment definition on both targets | The app declares a [`Radius.Data/postgreSqlDatabases`](../../../samples/OrderManagementApp/deploy/app.bicep) resource. The [Azure Local Recipe Pack](../../../recipe-packs/azure-local.bicep) picks the [CloudNativePG Recipe](../../../recipes/postgresql-database/azure-local/cloudnative-pg/postgres-database.bicep) or the [container Recipe](../../../recipes/postgresql-database/azure-local/postgres/postgres-database.bicep) by availability; on Azure it's the [flexible server Recipe](../../../recipes/postgresql-database/azure/flexible-server/postgres-flexible-database.bicep). All return the same `host`, `port`, `database` and `tls`. |
| The operator | Installed once per cluster by [provision-operators.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/provision-operators.ps1), with the Barman Cloud plugin. See the [operators README](../../../samples/OrderManagementApp/infra/azurelocal/operators/README.md). |
| Replicas and failover | Three instances on separate nodes, synchronous replication to at least one replica |
| Backups | The write-ahead log archived continuously and a daily base backup, kept 30 days, to the site's [object store](../../../samples/OrderManagementApp/infra/azurelocal/object-store/README.md) |
| Encryption | A server certificate from the site CA through cert-manager. Clients verify it: the platform gives every pod the CA in `PGSSLROOTCERT`, and [PostgresOptions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Configuration/PostgresOptions.cs) requires `VerifyFull`. |
| Choosing the credential at startup | [DatabaseCredentialProviders.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/DatabaseCredentialProviders.cs): a password when one is set, otherwise the pod's Entra workload identity; [PostgresDataSourceFactory.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Persistence/PostgresDataSourceFactory.cs) supplies it per connection |
| Schema and roles | [PostgresSetup.cs](../../../samples/OrderManagementApp/src/OrderManagement.DbSetup/PostgresSetup.cs) applies the [migrations](../../../samples/OrderManagementApp/src/OrderManagement.DbSetup/Migrations/Postgres) and creates the inventory role with row access only: an Entra principal on Azure, a password role on Azure Local |
| Passwords | Kept in Key Vault and synced into the cluster. See the [Key Vault guide](../../key-vault/README.md). |
| Monitoring | Alerts when an instance is down, a replica lags or log archiving stalls, in the site's [observability stack](../../../samples/OrderManagementApp/infra/azurelocal/observability/README.md) |
| Concurrent orders for the same stock | [PostgresStockRepository.cs](../../../samples/OrderManagementApp/src/OrderManagement.Inventory/Data/PostgresStockRepository.cs) locks the product rows and keys each reservation by order ID, so a redelivered order doesn't reserve twice |

## Not covered by the sample

The Recipe is sample code. Before production, add:

- a copy of the backups off the cluster, and a tested restore;
- a plan for PostgreSQL major version upgrades, with the same major version as on Azure;
- client certificates, if you want no stored password.

## References

- [CloudNativePG documentation](https://cloudnative-pg.io/docs/1.30/)
- [CloudNativePG backups](https://cloudnative-pg.io/docs/1.30/backup) and the [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/)
- [CloudNativePG certificates](https://cloudnative-pg.io/docs/1.30/certificates)
- [Microsoft Entra authentication with flexible server](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [Npgsql security and encryption](https://www.npgsql.org/doc/security.html)
- [Azure Well-Architected: Azure Database for PostgreSQL](https://learn.microsoft.com/azure/well-architected/service-guides/postgresql)
