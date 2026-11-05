# Operators on Azure Local

On Azure, the cloud runs the queue and the databases. On Azure Local, with `Common.Availability`
`high` (the default), operators do that job in the cluster. With `standard`, none of this is
installed.

| Operator | Runs | Install values |
| --- | --- | --- |
| [CloudNativePG](https://cloudnative-pg.io) | PostgreSQL: a primary and replicas on separate nodes, automatic failover | [cloudnative-pg/operator](./cloudnative-pg/operator/values.yaml) |
| [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/) | PostgreSQL backups to the site's object store | [cloudnative-pg/plugin-barman-cloud](./cloudnative-pg/plugin-barman-cloud/values.yaml) |
| [RabbitMQ Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview) | RabbitMQ on three nodes | [rabbitmq/cluster-operator](./rabbitmq/cluster-operator/kustomization.yaml) |
| RabbitMQ Messaging Topology Operator | The orders queue, its dead-letter queue and their policy | [rabbitmq/messaging-topology-operator](./rabbitmq/messaging-topology-operator/kustomization.yaml) |
| [cert-manager CSI driver](https://cert-manager.io/docs/usage/csi-driver/) | A certificate per RabbitMQ node, for TLS between the nodes | [rabbitmq/cert-manager-csi-driver](./rabbitmq/cert-manager-csi-driver/values.yaml) |

[provision-operators.ps1](../../../scripts/infra/azurelocal/provision-operators.ps1), the `Operators`
setup step, installs them from the in-cluster registry. Every connection, between clients and
servers and between replicas, uses TLS from the site CA.

## When something fails

| Failure | What happens |
| --- | --- |
| PostgreSQL primary | A replica is promoted in about 20 seconds; no committed transaction is lost. |
| RabbitMQ node | The other two keep serving; every queue has a copy on each node. |
| Keycloak pod | The other replica keeps serving. |

The cluster needs three workers so the replicas don't share one.

## Restoring a database

The write-ahead log is archived at least every 5 minutes and a base backup is taken daily, kept 30
days. To restore, create a new CloudNativePG `Cluster` that recovers from them, as in
[the plugin's documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/#restoring-a-cluster),
then point the app at it.