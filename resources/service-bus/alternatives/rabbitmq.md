# RabbitMQ as an alternative to Azure Service Bus

[RabbitMQ](https://www.rabbitmq.com/docs) is an open-source message broker you run yourself, here as a container in the Azure Local cluster. It provides the same point-to-point queue as Service Bus, but with its own client, protocol details and failure handling. Your application reaches it through an adapter rather than the Service Bus SDK.

## Service Bus features in RabbitMQ

| Service Bus | RabbitMQ | Notes |
|---|---|---|
| Namespace | Broker (virtual host) | You deploy and operate it. |
| Queue | Durable queue | Declare it as durable and publish messages as persistent. |
| Send | Publish to the default exchange with the queue name as routing key | |
| Receive in peek-lock mode | Consume with manual acknowledgement | |
| Complete | Acknowledge (`ack`) | |
| Abandon | Negative-acknowledge with requeue (`nack`) | Add your own delay; RabbitMQ redelivers immediately. |
| Lock duration | None | A message is redelivered when its channel closes or after the [consumer timeout](https://www.rabbitmq.com/docs/consumers#acknowledgement-timeout) (30 minutes by default). |
| Max delivery count and dead-letter queue | [Quorum queue](https://www.rabbitmq.com/docs/quorum-queues) delivery limit and a [dead-letter exchange](https://www.rabbitmq.com/docs/dlx) | Not automatic on classic queues: a failing message is redelivered indefinitely. |
| Message ID, content type, subject | `message_id`, `content_type`, `type` properties | |
| Sessions, scheduled messages, duplicate detection | No built-in equivalent | Handle them in the application, or use a plugin. |
| Shared access key (connection string) | Username and password | Stored in a Kubernetes Secret; the sample's Recipe generates them when no identity provider is set. |
| Entra ID with workload identity federation | [OAuth 2.0 plugin](https://www.rabbitmq.com/docs/oauth2) with your own identity provider | The pod's service account token is exchanged for an access token, which is sent as the password. The broker closes the connection when the token expires, so the client reconnects with a new one. |

RabbitMQ 4.0 and later also speak [AMQP 1.0](https://www.rabbitmq.com/docs/amqp), the protocol Service Bus uses. That doesn't make the Service Bus SDK a drop-in client: addresses, authentication and management operations differ. This project didn't evaluate it.

## How the Order Management sample does it

The sample keeps one codebase and one set of images for both targets by putting the broker behind an adapter:

```text
API and processor  ──►  IMessagePublisher / IMessageSubscriber
                               │  chosen at startup from `provider`
                ┌──────────────┴──────────────┐
      ServiceBusMessageBroker          RabbitMqMessageBroker
       (Azure Service Bus SDK)          (RabbitMQ.Client)
```

| Step | In the sample |
|---|---|
| Interfaces the application codes against | [IMessagePublisher.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/IMessagePublisher.cs) |
| One adapter per broker | [ServiceBusMessageBroker.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/ServiceBusMessageBroker.cs), [RabbitMqMessageBroker.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Messaging/RabbitMqMessageBroker.cs): acknowledge, requeue after 5 seconds, reconnect |
| Choosing the adapter at startup | [ServiceCollectionExtensions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs) reads `provider` (`servicebus` or `rabbitmq`) |
| Idempotent handling | [SqlOrderStore.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Persistence/SqlOrderStore.cs) writes with `MERGE`, so a redelivered order isn't stored twice |
| Token instead of a password | [WorkloadTokenProvider.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Identity/WorkloadTokenProvider.cs) exchanges the pod's token at Keycloak; see the sample's [authentication page](../../../samples/OrderManagementApp/docs/authentication.md) |
| Same deployment definition on both targets | The app declares a portable queue type, [`Portability.Messaging/messageQueues`](../../../recipes/message-queue/messageQueues.yaml). Each target's Radius Recipe creates the broker and returns `provider` and `endpoint`: [Service Bus](../../../recipes/message-queue/azure/service-bus/servicebus-queue.bicep), [RabbitMQ](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep). |

The sample doesn't use Radius's [`Radius.Messaging/rabbitMQ`](https://github.com/radius-project/resource-types-contrib/tree/main/Messaging/rabbitMQ) type. That type is RabbitMQ-specific, so Service Bus can't back it, and it supports passwords only.

## Not covered by the sample

The [RabbitMQ Recipe](../../../recipes/message-queue/azure-local/rabbitmq/rabbitmq-queue.bicep) is sample code. Before production, add:

- a persistent volume, so queued messages survive a pod restart;
- more than one replica, with quorum queues;
- a delivery limit and dead-lettering (the queue type's `maxDeliveryCount` isn't applied);
- TLS on the AMQP listener;
- separate credentials for the management interface.

## References

- [RabbitMQ documentation](https://www.rabbitmq.com/docs)
- [Asynchronous messaging options on Azure](https://learn.microsoft.com/azure/architecture/guide/technology-choices/messaging)
- [Anti-corruption Layer pattern](https://learn.microsoft.com/azure/architecture/patterns/anti-corruption-layer), the idea behind the adapter
- [Service Bus dead-letter queues](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-dead-letter-queues)
