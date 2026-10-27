# Azure Service Bus → Azure Local

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [RabbitMQ](./alternatives/rabbitmq.md) | `adapter-required` | Sample available | Self-hosted broker with its own addressing, authentication and failure handling. |
| Azure Local | [Apache Kafka](https://kafka.apache.org/documentation/) | — | Documentation available | Not evaluated by this project. See the linked documentation. |

## What carries over

- Point-to-point queue semantics: send, receive, acknowledge, redeliver on failure.
- JSON message payloads, message ID, content type and message type, and the application's handler logic.
- The application definition. The application declares a queue through the portable Resource Type `Portability.Messaging/messageQueues`, not Service Bus by name. Each environment's Recipe Pack chooses the Recipe that provides it.
- Secret-free authentication. On both targets the pod's Kubernetes service account token is exchanged for an access token; only the issuer changes.

## Required application changes

A second broker implementation behind the same publish and subscribe interfaces, plus code that chooses one at startup from the `provider` value the Recipe returns. The handler logic is unchanged. Redelivery must be safe on both brokers, so the handler has to be idempotent. Details are in the [RabbitMQ page](./alternatives/rabbitmq.md).

## Observed limitations, by pattern

| Pattern (Microsoft Learn) | Limitation for this resource |
|---|---|
| Messaging | RabbitMQ 4.0+ also speaks AMQP 1.0, but addressing, authentication and management are broker-specific, so the Service Bus SDK is not a drop-in client. The sample uses RabbitMQ's own AMQP 0-9-1 client. The broker is hosted, patched and monitored by the customer. Dead-lettering, lock duration and delivery counts are not provided automatically. |
| Identity | Entra workload identity itself is not available. The same federated, secret-free pattern works through OAuth 2.0 with the customer's own identity provider (Keycloak in the sample). The alternative is a generated password. |
| Storage | The reference Recipe does not mount a data volume, so queued messages are lost if the broker pod is rescheduled. |

**Data:** messages waiting in Service Bus are not carried to the new broker. Drain the queue before switching, or accept that in-flight messages are lost.

## Examples

The [Order Management sample](../../samples/OrderManagementApp/README.md) covers this resource, so there is no separate example. It runs the same API and processor against Service Bus on Azure and RabbitMQ on Azure Local:

| What | Where |
|---|---|
| Resource Type | [messageQueues.yaml](../../recipes/message-queue/messageQueues.yaml) |
| Recipe, Azure | [servicebus-queue.bicep](../../recipes/message-queue/azure/service-bus/servicebus-queue.bicep): namespace and queue, local authentication disabled, Data Sender and Data Receiver roles for the workload identity |
| Recipe, Azure Local | [rabbitmq-queue.bicep](../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep): RabbitMQ container, OAuth 2.0 when an issuer is set, otherwise a generated password |
| Recipe Packs | [azure.bicep](../../recipe-packs/azure.bicep), [azure-local.bicep](../../recipe-packs/azure-local.bicep) |
| Application definition | [app.bicep](../../samples/OrderManagementApp/deploy/app.bicep): the `orders` queue and the connections to it |
| Broker implementations | [ServiceBusMessageBroker.cs](../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/ServiceBusMessageBroker.cs), [RabbitMqMessageBroker.cs](../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/RabbitMqMessageBroker.cs) |
| Choosing the broker | [ServiceCollectionExtensions.cs](../../samples/OrderManagementApp/src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs) |
| Authentication | [authentication.md](../../samples/OrderManagementApp/docs/authentication.md) |
