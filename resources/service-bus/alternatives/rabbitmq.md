# RabbitMQ as an alternative to Azure Service Bus

> **Draft.** Based on the [Order Management sample](../../../samples/OrderManagementApp/README.md).

On Azure Local, RabbitMQ provides the queue that Azure Service Bus provides on Azure. The sample runs it as a container in the cluster, created by a Recipe.

## How it fits together

```text
API / processor                       declare a queue, never name a broker
        │
        ▼
Resource Type                         Portability.Messaging/messageQueues
        │   (the environment's Recipe Pack chooses the Recipe)
        ├── Azure pack                Service Bus Recipe  → Azure Service Bus
        └── Azure Local pack          RabbitMQ Recipe     → RabbitMQ container
```

At startup the application reads the `provider` value that the Recipe returns (`rabbitmq` or `servicebus`) and creates the matching client. The rest of the application only sees a publish interface and a subscribe interface.

### Why not the upstream `Radius.Messaging/rabbitMQ` type?

Radius ships a community [`Radius.Messaging/rabbitMQ`](https://github.com/radius-project/resource-types-contrib/tree/main/Messaging/rabbitMQ) type. It promises the application a RabbitMQ broker, so a Recipe can't return Service Bus for it, and the application definition would have to change between targets. Its Kubernetes Recipe also only supports a password and pulls from Docker Hub, which rules out token authentication and the connected registry on Azure Local.

The sample therefore defines its own type, [`Portability.Messaging/messageQueues`](../../../recipes/message-queue/messageQueues.yaml), which describes a durable queue rather than a protocol. The trade-off: the type can only promise settings that both brokers can honour, and the application still needs a client per broker. If the application only ever needs RabbitMQ with a password, the upstream type is simpler.

## Differences the application will notice

| | Azure Service Bus (Azure) | RabbitMQ (Azure Local) |
|---|---|---|
| Protocol and client | AMQP 1.0, Azure Service Bus SDK, over WebSockets | The sample uses RabbitMQ's AMQP 0-9-1 client. RabbitMQ 4.0+ also supports AMQP 1.0 (see below) |
| Authentication | Entra workload identity; local keys disabled; the identity needs the Data Sender and Data Receiver roles | OAuth 2.0 access token from a customer-operated identity provider, obtained with the same federated flow, or a generated username and password |
| Failed message | Abandoned, redelivered up to a maximum delivery count (default 10), then dead-lettered | Negative-acknowledged and requeued after a 5 second delay |
| Poison message | Ends in the dead-letter queue | Redelivered indefinitely unless a dead-letter policy is added |
| Duplicate delivery | Possible after a lock expires | Possible when a channel closes before the acknowledgement; the sample's SQL `MERGE` makes processing idempotent on both |
| Message properties | Message ID, content type, and the message type as `Subject` | Message ID, content type, and the message type as `type`; marked persistent |
| Lock or visibility | 1 minute lock per message | Unacknowledged messages are redelivered when the channel closes |
| Connection lifetime | Managed by the SDK | With OAuth, the broker closes the connection when the token expires; the application reconnects with a new token |

## Can RabbitMQ 4 be used with the Service Bus client?

RabbitMQ supports [AMQP 1.0 natively](https://www.rabbitmq.com/docs/amqp) since version 4.0, alongside AMQP 0-9-1. That narrows the protocol gap, but it does not make RabbitMQ a Service Bus look-alike, because AMQP 1.0 leaves several things to each broker:

| Area | Azure Service Bus | RabbitMQ 4 |
|---|---|---|
| Addresses | An entity path such as the queue name | Its own format, such as `/queues/<name>`; the AMQP specification does not define how addresses resolve |
| Authentication | Claims-based security: the client sends tokens over the AMQP connection, so the SDK can use Entra identities | SASL is required; mechanisms include PLAIN, ANONYMOUS, EXTERNAL and OAuth 2.0 tokens |
| Management operations | Lock renewal, message browsing and sessions are request and response exchanges on top of AMQP | Not the same operations |
| Features | Dead-letter queues, sessions, scheduled messages, duplicate detection | Queue types, exchanges and policies of its own |

The Service Bus SDK is built for Service Bus. Whether it works against RabbitMQ unchanged was not evaluated here. The sample uses RabbitMQ's AMQP 0-9-1 client, which is why the first table shows 0-9-1.

## Authentication options

1. **Password.** The Recipe generates a username and password. Radius stores them in a Kubernetes Secret, and the application receives them through its connection to the queue.
2. **OAuth 2.0 with a customer-operated identity provider.** This is the same federated pattern Entra workload identity uses, with a different issuer. Set the issuer on the Azure Local Recipe Pack (`oauthIssuer`). The application sends its projected Kubernetes service account token to the issuer's token endpoint as a client assertion (`client_credentials` grant with a JWT bearer assertion), receives an access token, and presents it to RabbitMQ as the password. No secret is stored: the cluster issues and rotates the service account token. Authorization travels in the token, so RabbitMQ keeps no user record for the workload. The sample uses Keycloak federated with Active Directory; see its [authentication page](../../../samples/OrderManagementApp/docs/authentication.md) and the [RabbitMQ OAuth 2.0 guide](https://www.rabbitmq.com/docs/oauth2).

## Observed limitations of the reference Recipe

The [reference Recipe](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep) is sample code. As written it has these limitations:

- **No data volume.** Queues and messages are declared durable, but nothing persists the broker's data directory, so messages are lost if the pod is rescheduled.
- **Single pod.** The Recipe does not set replicas or a clustered queue type.
- **No dead-lettering.** The queue type's `maxDeliveryCount` setting is not applied by this Recipe.
- **No TLS on the AMQP listener.**
- **Management interface** is exposed on its own port and still uses the generated password.

## Required application changes

Each item links to where the Order Management sample does it.

- A RabbitMQ implementation of the publish and subscribe interfaces, with its own acknowledge, retry and reconnect behaviour: [RabbitMqMessageBroker.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/RabbitMqMessageBroker.cs).
- A selector that chooses the implementation from the `provider` value: [ServiceCollectionExtensions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs).
- With OAuth, a small token provider that reads the projected service account token and refreshes access tokens: [WorkloadTokenProvider.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/WorkloadTokenProvider.cs).
- Idempotent processing, because both brokers can deliver a message more than once: [SqlOrderStore.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Persistence/SqlOrderStore.cs).

## References

- [RabbitMQ AMQP 1.0 support](https://www.rabbitmq.com/docs/amqp)
- [RabbitMQ OAuth 2.0 authentication and authorization](https://www.rabbitmq.com/docs/oauth2)
- [RabbitMQ persistence configuration](https://www.rabbitmq.com/docs/persistence-conf)
- [AMQP 1.0 in Azure Service Bus](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-amqp-overview)
- [AMQP 1.0 protocol guide for Azure Service Bus](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-amqp-protocol-guide)
- [Service Bus dead-letter queues](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues)
