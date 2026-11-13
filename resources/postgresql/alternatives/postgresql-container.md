# PostgreSQL container as an alternative to Azure Database for PostgreSQL

The official [PostgreSQL image](https://hub.docker.com/_/postgres) can run in the cluster as a single instance: one StatefulSet, its data on a persistent volume, no operator. It runs the same engine as flexible server, so the application keeps its driver, SQL and schema. It has no replicas, failover or backups; [CloudNativePG](./cloudnative-pg.md), the other alternative explored, provides them.

## How flexible server features map to the container

| Flexible server | PostgreSQL container | Notes |
|---|---|---|
| Server | StatefulSet and Service in the application's namespace | You deploy and operate it. |
| Database, roles | Created by a setup job as the administrator | The same job runs on Azure. |
| Compute and storage tiers | Pod CPU and memory, persistent volume size and storage class | |
| Microsoft Entra authentication | Password roles (SCRAM-SHA-256) | |
| TLS with a public certificate | TLS with a certificate from cert-manager, verified by clients against the site CA | The server reloads a renewed certificate without a restart. |
| Automatic backups, point-in-time restore | None | Schedule `pg_dump` or volume snapshots, and copy them off the cluster. |
| High availability | None; one instance | A node failure stops the database until the pod restarts elsewhere. |
| Server parameters | Command-line options and configuration files in the Recipe | |
| Firewall rules, private access | Kubernetes Service and network policies | Reachable inside the cluster only. |
| Major version upgrades | Change the image tag, dump and restore | Pin the tag; don't let it float across major versions. |

## How the Order Management sample does it

The sample uses this container when its `Availability` setting is `standard`. The application, roles, passwords and TLS work as with [CloudNativePG](./cloudnative-pg.md#how-the-order-management-sample-does-it); only the Recipe differs:

| Step | In the sample |
|---|---|
| The server | [postgres-database.bicep](../../../recipes/postgresql-database/azure-local/postgres/postgres-database.bicep): a StatefulSet, a persistent volume, `hostssl` with password authentication, a certificate from the site CA, and a sidecar that reloads renewed certificates and changed passwords |
| Choosing it | The [Azure Local Recipe Pack](../../../recipe-packs/azure-local.bicep) with availability `standard` |

## Not covered by the sample

The sample's setup is for demonstration. Depending on your workload's requirements, a production deployment might also need:

- backups and a tested restore, kept off the cluster;
- a replica and failover, which the [CloudNativePG](./cloudnative-pg.md) alternative provides.

## References

- [PostgreSQL Docker Official Image](https://hub.docker.com/_/postgres)
- [PostgreSQL client authentication](https://www.postgresql.org/docs/current/client-authentication.html)
- [CloudNativePG documentation](https://cloudnative-pg.io/docs/1.30/)
