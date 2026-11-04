# Operators on Azure Local

On Azure, the cloud runs the queue and the databases: it keeps replicas, fails over, patches and
backs up. On Azure Local, operators do that job inside the cluster, when `Common.Availability` is
`high` (the default). The Recipes only declare what the app needs, and the operator makes it so.
With `standard`, nothing here is installed and the `rabbitmq` and `postgres` Recipes run one
container of each instead.

| Operator | Runs | The Recipe declares |
| --- | --- | --- |
| [CloudNativePG](https://cloudnative-pg.io) (Apache 2.0, CNCF) | PostgreSQL: a primary and replicas on separate nodes, automatic failover, rolling updates | a `Cluster` ([postgres-database.bicep](../../../../../recipes/postgresql-database/azure-local/cloudnative-pg/postgres-database.bicep)) |
| [Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/) (Apache 2.0) | PostgreSQL backups: the write-ahead log continuously, a base backup daily | an `ObjectStore` and a `ScheduledBackup` |
| [RabbitMQ Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview) (MPL 2.0) | RabbitMQ: three nodes, rolling upgrades | a `RabbitmqCluster` ([rabbitmq-queue.bicep](../../../../../recipes/message-queue/azure-local/rabbitmq-cluster-operator/rabbitmq-queue.bicep)) |
| RabbitMQ Messaging Topology Operator (MPL 2.0) | Queues and policies inside those clusters | the orders queue, its dead-letter queue and the policy between them |
| [cert-manager CSI driver](https://cert-manager.io/docs/usage/csi-driver/) (Apache 2.0) | A certificate for each RabbitMQ pod, from the site CA, which the nodes present to each other | nothing: the `RabbitmqCluster` asks for it (`tls.interNode`) |

Every connection is encrypted and verified against the site CA. PostgreSQL serves TLS with a
certificate from it and its replicas stream to each other over TLS. RabbitMQ accepts clients over
TLS only (AMQP on 5671, its management API and metrics too), and its nodes replicate to each other
over mutual TLS. The topology operator and Prometheus reach the brokers over HTTPS and trust the
site CA, which the setup steps copy into their namespaces as Secret `oms-site-ca`.

Keycloak's database is a CloudNativePG `Cluster` too, in [../keycloak/database/cloudnative-pg.yaml](../keycloak/database/cloudnative-pg.yaml).

| File | What it installs |
| --- | --- |
| [cloudnative-pg/operator/values.yaml](./cloudnative-pg/operator/values.yaml) | CloudNativePG, from its Helm chart, into `cnpg-system` |
| [cloudnative-pg/plugin-barman-cloud/values.yaml](./cloudnative-pg/plugin-barman-cloud/values.yaml) | The Barman Cloud plugin, into `cnpg-system` |
| [rabbitmq/cluster-operator](./rabbitmq/cluster-operator/kustomization.yaml) | The RabbitMQ Cluster Operator release, into `rabbitmq-system` |
| [rabbitmq/messaging-topology-operator](./rabbitmq/messaging-topology-operator/kustomization.yaml) | The Messaging Topology Operator release, into `rabbitmq-system` |
| [rabbitmq/cert-manager-csi-driver/values.yaml](./rabbitmq/cert-manager-csi-driver/values.yaml) | The cert-manager CSI driver, from its Helm chart, into `cert-manager-csi-driver` |

[provision-operators.ps1](../../../scripts/infra/azurelocal/provision-operators.ps1) installs them,
the `Operators` step of `setup-platform.ps1`, which skips it with `standard`. Each file says how to
install it by hand. Every image is
pulled from the connected registry, so the operators, and what they run, keep working when the link
to Azure is down. Their webhooks get certificates from the cluster's cert-manager.

## What happens when something fails

| Failure | What the operator does |
| --- | --- |
| A PostgreSQL primary's pod or node | Promotes the most up-to-date replica and points the `-rw` Service, which the app connects to, at it. The old primary rejoins as a replica. No committed transaction is lost: a commit returns only once a replica has it too (synchronous replication, `dataDurability: preferred`). While no replica is available, commits don't wait for one, so writes carry on but a failover in that window could lose the latest ones. To refuse failover rather than risk that, set `postgresql.synchronous.failoverQuorum: true` in the Recipe, at the cost of staying down until enough instances are back. On the test site failover took about 20 seconds; the first request on a connection to the old primary fails, and later ones go to the new one. |
| A RabbitMQ node | The other two keep serving. Every queue is a quorum queue with a copy on each node, so no message is lost; the node rejoins and catches up when it's back. |
| A Keycloak pod | The other replica keeps serving; sessions are shared between them. The replacement joins the cluster and takes its share of the sessions back. |

The replicas spread one per worker, so the cluster needs three workers for the RabbitMQ nodes and the
PostgreSQL instances not to share one.

## Restoring a database

Backups go to the site's object store, as [../object-store/README.md](../object-store/README.md)
describes. The write-ahead log is archived at least every 5 minutes, so a restore can lose up to the
last 5 minutes of changes. To restore, create a new CloudNativePG `Cluster` that recovers from them,
to the latest point or to a point in time, as in
[the plugin's documentation](https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/#restoring-a-cluster),
then point the app at it.

A cluster can't archive into a path that already has another cluster's backups. If you delete the
app's database and deploy it again under the same name, restore it from the backups, or move the old
ones aside first.
