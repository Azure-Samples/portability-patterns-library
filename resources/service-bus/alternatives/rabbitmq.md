# RabbitMQ as an alternative to Azure Service Bus

[RabbitMQ](https://www.rabbitmq.com/docs) is an open-source message broker (MPL-2.0) you run yourself, here in the Azure Local cluster. It provides the same point-to-point queue as Service Bus, but with its own client, protocol details and failure handling. Your application reaches it through an adapter rather than the Service Bus SDK.

## Running it in the cluster

| | RabbitMQ Cluster Operator | Single broker |
|---|---|---|
| What runs | A `RabbitmqCluster` the [Cluster Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview) manages: three nodes on separate cluster nodes, rolling upgrades. Queues and policies are Kubernetes resources the Messaging Topology Operator applies. | One StatefulSet from the official image, no operator |
| Losing a node | Quorum queues are replicated to every node: no message is lost and the queue stays available | The queue stops until the pod restarts elsewhere |
| Operating effort | Install two operators once per cluster | None beyond the broker |
| Licence | MPL-2.0 (operators and broker) | MPL-2.0 |

Both keep each node's data on a persistent volume and can accept TLS only.

## Service Bus features in RabbitMQ

| Service Bus | RabbitMQ | Notes |
|---|---|---|
| Namespace | Broker or cluster (virtual host) | You deploy and operate it. |
| Queue | Durable [quorum queue](https://www.rabbitmq.com/docs/quorum-queues) | Publish messages as persistent, and keep the broker's data on a persistent volume. |
| Premium zone redundancy | A three-node cluster with quorum queues | The sample spreads the RabbitMQ nodes over the AKS cluster's worker nodes. Azure Local offers [local availability zones](https://learn.microsoft.com/azure/azure-local/concepts/rack-aware-cluster-overview) on rack aware clusters and disaggregated deployments. The sample doesn't use them. |
| Send | Publish to the default exchange with the queue name as routing key | Turn on publisher confirms and publish as mandatory, so a message the broker refuses or can't route is an error, as a failed Service Bus send is. |
| Receive in peek-lock mode | Consume with manual acknowledgement | Prefetch no more messages than the handler works on at once. |
| Complete | Acknowledge (`ack`) | |
| Abandon | Negative-acknowledge with requeue (`nack`) | Add your own delay; RabbitMQ redelivers immediately. |
| Lock duration | None | A message is redelivered when its channel closes or after the [consumer timeout](https://www.rabbitmq.com/docs/consumers#acknowledgement-timeout) (30 minutes by default). |
| Max delivery count and dead-letter queue | A second queue, and a policy with a delivery limit and a [dead-letter exchange](https://www.rabbitmq.com/docs/dlx) | A requeue doesn't count towards the limit, so the consumer reads the delivery count (`x-acquired-count`) and rejects the message without requeue on the last attempt. Classic queues report no count, so a failing message is redelivered indefinitely. |
| Message ID, content type, subject | `message_id`, `content_type`, `type` properties | |
| Application properties | Message headers | For example the W3C trace context, so one message is one trace across services. |
| TLS 1.2, always on | TLS listeners only (AMQPS on 5671), with a certificate the client verifies | Turn the plain listeners off. Nodes can replicate to each other over mutual TLS. |
| Sessions, scheduled messages, duplicate detection | No built-in equivalent | Handle them in the application, or use a plugin. |
| Shared access key (connection string) | Username and password | Stored in a Kubernetes Secret. |
| Entra ID with workload identity federation | [OAuth 2.0 plugin](https://www.rabbitmq.com/docs/oauth2) with your own identity provider | The pod's service account token is exchanged for an access token, which is sent as the password. Refresh the token on the open connection before it expires (RabbitMQ.Client's `CredentialsRefresher`), or the broker closes the connection. |
| Azure role assignments (Data Sender, Data Receiver) | Permissions in the token's scopes claim | |

RabbitMQ 4.0 and later also speak [AMQP 1.0](https://www.rabbitmq.com/docs/amqp), the protocol Service Bus uses. That doesn't make the Service Bus SDK a drop-in client: addresses, authentication and management operations differ. This project didn't evaluate it.

## How the Order Management sample does it

The sample keeps one codebase and one set of images for both targets by putting the broker behind an adapter:

```text
API and processor  ──►  IMessageQueue
                               │  chosen at startup from `provider`
                ┌──────────────┴──────────────┐
      ServiceBusMessageBroker          RabbitMqMessageBroker
       (Azure Service Bus SDK)          (RabbitMQ.Client)
```

| Step | In the sample |
|---|---|
| Interfaces the application codes against | [IMessageQueue.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/IMessageQueue.cs): publish, and run a handler per message; returning acknowledges, throwing hands the message back |
| One adapter per broker | [ServiceBusMessageBroker.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/ServiceBusMessageBroker.cs), [RabbitMqMessageBroker.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/RabbitMqMessageBroker.cs): publisher confirms, acknowledge, requeue, one recovering connection, no more prefetched than handled at once. The queues are the platform's: the Recipes declare them, the application doesn't. |
| Riding out a dependency outage | [ProcessorOptions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Processor/ProcessorOptions.cs): the processor retries a failed step 5 times, for about a minute, before the broker redelivers. A short restart or failover then doesn't use up the message's deliveries. |
| Choosing the adapter at startup | [QueueOptions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Configuration/QueueOptions.cs) and [ServiceCollectionExtensions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs) read `provider` (`servicebus` or `rabbitmq`) and `tls` |
| Same deployment definition on both targets | The app declares a portable queue type, [`Portability.Messaging/messageQueues`](../../../recipes/message-queue/messageQueues.yaml). Each target's Radius Recipe creates the broker and returns `provider`, `endpoint` and `tls`: [Service Bus](../../../recipes/message-queue/azure/service-bus/servicebus-queue.bicep), and on Azure Local the [RabbitMQ operator Recipe](../../../recipes/message-queue/azure-local/rabbitmq-cluster-operator/rabbitmq-queue.bicep) (availability `high`, the default) or the [single broker Recipe](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep) (`standard`), chosen by the [Recipe Pack](../../../recipe-packs/azure-local.bicep). |
| The operators | Installed once per cluster by [provision-operators.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/provision-operators.ps1). See the [operators README](../../../samples/OrderManagementApp/infra/azurelocal/operators/README.md). |
| Dead-lettering after `maxDeliveryCount` (10) attempts, as on Service Bus | Both Recipes create `orders` and `orders.dead-letter` as quorum queues with a dead-letter policy. The adapter marks the last attempt, and [OrderProcessor.cs](../../../samples/OrderManagementApp/src/OrderManagement.Processor/OrderProcessor.cs) releases the order's stock before it's dead-lettered, unless the order was recorded. |
| Idempotent handling | [SqlOrderStore.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Persistence/SqlOrderStore.cs) writes with `MERGE`, and the inventory service keys reservations by order ID, so a redelivered order isn't stored or reserved twice |
| Encryption | AMQPS only, with a certificate from the site CA that the client verifies; the nodes replicate over mutual TLS with certificates from the cert-manager CSI driver |
| Token instead of a password | Required on Azure Local: each service exchanges its own service account token at Keycloak ([WorkloadIdentity.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/WorkloadIdentity.cs), with Duende.AccessTokenManagement), and [KeycloakCredentialsProvider.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/KeycloakCredentialsProvider.cs) gives the token to RabbitMQ and refreshes it on the open connection. See the [workload identity guide](../../workload-identity/README.md). |
| One trace per order | The RabbitMQ client and the Service Bus SDK carry the trace context in the message themselves; [TelemetryExtensions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Diagnostics/TelemetryExtensions.cs) collects their spans |
| Monitoring | Alerts on dead-lettered messages and a stalled processor, on both targets |

The sample doesn't use Radius's [`Radius.Messaging/rabbitMQ`](https://github.com/radius-project/resource-types-contrib/tree/main/Messaging/rabbitMQ) type. That type is RabbitMQ-specific, so Service Bus can't back it, and it supports passwords only.

## Not covered by the sample

The sample's setup is for demonstration. Depending on your workload's requirements, a production deployment might also need:

- a copy of the broker's definitions, and a plan for messages if the whole cluster is lost: replication protects against losing a node, not the cluster;
- rotation of the administrator's password, which the operators and the management interface use (it can't open messaging connections);
- capacity planning for the nodes' volumes, which the sample keeps small;
- with a single broker, a second node: use the operator.

## References

- [RabbitMQ documentation](https://www.rabbitmq.com/docs)
- [RabbitMQ Cluster Kubernetes Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview)
- [Quorum queues](https://www.rabbitmq.com/docs/quorum-queues)
- [RabbitMQ OAuth 2.0](https://www.rabbitmq.com/docs/oauth2)
- [Asynchronous messaging options on Azure](https://learn.microsoft.com/azure/architecture/guide/technology-choices/messaging)
- [Anti-corruption Layer pattern](https://learn.microsoft.com/azure/architecture/patterns/anti-corruption-layer), the idea behind the adapter
- [Service Bus dead-letter queues](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-dead-letter-queues)
