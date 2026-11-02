# PostgreSQL container as an alternative to Azure Database for PostgreSQL

On Azure Local, the official [PostgreSQL image](https://hub.docker.com/_/postgres) runs in the cluster and provides the database that flexible server provides on Azure. The sample creates it with a Radius Recipe: one StatefulSet, its data on a persistent volume. Because it's the same engine, the application keeps its driver, SQL and schema.

## Flexible server features in the container

| Flexible server | PostgreSQL container | Notes |
|---|---|---|
| Server | StatefulSet and Service in the application's namespace | You deploy and operate it. |
| Database, roles | Created by a setup job as the administrator | The same job runs on Azure. |
| Compute and storage tiers | Pod CPU and memory, persistent volume size and storage class | |
| Microsoft Entra authentication | Password roles (SCRAM-SHA-256) | Or client certificates, which this sample doesn't use. |
| TLS with a public certificate | TLS with a certificate from cert-manager | The server reloads a renewed certificate without a restart. |
| Automatic backups, point-in-time restore | None | Schedule `pg_dump` or volume snapshots, and copy them off the cluster. |
| High availability (standby) | None; one instance | Use an operator such as [CloudNativePG](https://cloudnative-pg.io/docs/1.30/) for replicas and failover. |
| Server parameters | Command-line options and configuration files in the Recipe | |
| [Extensions](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-extensions) allow-list | Whatever the image contains | Standard contrib extensions are included. |
| Firewall rules, private access | Kubernetes Service and network policies | Reachable inside the cluster only. |
| Major version upgrades | Change the image tag, dump and restore | Pin the tag; don't let it float across major versions. |

## How the Order Management sample does it

The inventory service owns products and stock. It reaches PostgreSQL the same way on both targets:

```text
Inventory service  ──►  NpgsqlDataSource with a password provider
                               │  credential chosen at startup
                ┌──────────────┴──────────────┐
      Entra access token               Role password
   (flexible server, Azure)       (container, Azure Local)
```

| Step | In the sample |
|---|---|
| Same deployment definition on both targets | The app declares a [`Radius.Data/postgreSqlDatabases`](../../../samples/OrderManagementApp/deploy/app.bicep) resource. Each target's Recipe creates the database and returns `host`, `port`, `database` and `tls`: [flexible server](../../../recipes/postgresql-database/azure/flexible-server/postgres-flexible-database.bicep), [container](../../../recipes/postgresql-database/azure-local/postgres/postgres-database.bicep). |
| Choosing the credential at startup | [DatabaseCredentialProviders.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/DatabaseCredentialProviders.cs): a password when one is set, otherwise the pod's Entra workload identity |
| Token or password per connection | [PostgresDataSourceFactory.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Persistence/PostgresDataSourceFactory.cs) uses Npgsql's `UsePeriodicPasswordProvider` for both |
| Roles with only the rights they need | [PostgresSetup.cs](../../../samples/OrderManagementApp/src/OrderManagement.DbSetup/PostgresSetup.cs), run as a job by the deploy scripts: an Entra principal for the inventory identity on Azure (`pgaadauth_create_principal_with_oid`), a password role on Azure Local; row access to the `inventory` schema only |
| Passwords | Kept in Key Vault and synced into the cluster. See the [Key Vault guide](../../key-vault/README.md). |
| Encryption | The container Recipe gets a certificate from the site CA through cert-manager and requires TLS (`hostssl`) for network connections |
| Concurrent orders for the same stock | [PostgresStockRepository.cs](../../../samples/OrderManagementApp/src/OrderManagement.Inventory/Data/PostgresStockRepository.cs) locks the product rows (`SELECT ... FOR UPDATE`) and keys each reservation by order ID, so a redelivered order doesn't reserve twice |

## Not covered by the sample

The Recipe is sample code. Before production, add:

- backups and a tested restore, kept off the cluster;
- a replica and failover, for example with CloudNativePG;
- verification of the server certificate by the client;
- a pinned image tag, the same major version as on Azure.

## References

- [PostgreSQL Docker Official Image](https://hub.docker.com/_/postgres)
- [CloudNativePG documentation](https://cloudnative-pg.io/docs/1.30/)
- [Microsoft Entra authentication with flexible server](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [Manage Microsoft Entra roles in flexible server](https://learn.microsoft.com/azure/postgresql/flexible-server/how-to-manage-azure-ad-users)
- [Npgsql security and encryption](https://www.npgsql.org/doc/security.html)
- [PostgreSQL client authentication](https://www.postgresql.org/docs/current/client-authentication.html)
- [Azure Well-Architected: Azure Database for PostgreSQL](https://learn.microsoft.com/azure/well-architected/service-guides/postgresql)
