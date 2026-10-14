# Azure Service Bus → RabbitMQ

> **Draft.** Based on the Order Management sample. Values marked in angle brackets are placeholders.

RabbitMQ replaces Azure Service Bus as the queue on Azure Local. The sample runs it as a container in the cluster, created by a recipe.

## How it fits together

```text
Order Intake / Order Processor      declare a queue, never name a broker
        │
        ▼
Resource Type                       BusinessContinuity.Messaging/messageQueues
        │   (the environment's recipe pack chooses the recipe)
        ├── Azure pack                Service Bus recipe  → Azure Service Bus
        └── Azure Local packs         RabbitMQ recipe     → RabbitMQ container
```

At startup the worker reads the `provider` value that the recipe publishes (`rabbitmq` or `servicebus`) and creates the matching client. The rest of the worker only sees a publish interface and a subscribe interface.

## Differences the application will notice

| | Azure Service Bus (Azure) | RabbitMQ (Azure Local) |
|---|---|---|
| Protocol and client | AMQP 1.0, Azure Service Bus SDK, over WebSockets | The sample uses RabbitMQ's AMQP 0-9-1 client. RabbitMQ 4.0+ also supports AMQP 1.0 (see below) |
| Authentication | Entra workload identity; local keys disabled; the identity needs the Data Sender and Data Receiver roles | OAuth 2.0 access token from your own identity provider, obtained with the same federated flow, or a generated username and password |
| Failed message | Abandoned, redelivered up to a maximum delivery count (default 10), then dead-lettered | Negative-acknowledged and requeued after a 5 second delay |
| Poison message | Ends in the dead-letter queue | Redelivered indefinitely unless you add a dead-letter policy |
| Message properties | `region` and `severity` are sent as application properties | The sample's RabbitMQ publisher sets message id, content type and type, but not these two |
| Lock or visibility | 1 minute lock per message | Unacknowledged messages are redelivered when the channel closes |
| Connection lifetime | Managed by the SDK | With OAuth, the broker closes the connection when the token expires; the worker reconnects with a new token |

## Can RabbitMQ 4 be used with the Service Bus client?

RabbitMQ supports [AMQP 1.0 natively](https://www.rabbitmq.com/docs/amqp) since version 4.0, alongside AMQP 0-9-1. That narrows the protocol gap, but it does not make RabbitMQ a Service Bus look-alike, because AMQP 1.0 leaves several things to each broker:

| Area | Azure Service Bus | RabbitMQ 4 |
|---|---|---|
| Addresses | An entity path such as the queue name | Its own format, such as `/queues/<name>`; the AMQP specification does not define how addresses resolve |
| Authentication | Claims-based security: the client sends tokens over the AMQP connection, so the SDK can use Entra identities | SASL is required; mechanisms include PLAIN, ANONYMOUS, EXTERNAL and OAuth 2.0 tokens |
| Management operations | Lock renewal, message browsing and sessions are request and response exchanges on top of AMQP | Not the same operations |
| Features | Dead-letter queues, sessions, scheduled messages, duplicate detection | Queue types, exchanges and policies of its own |

What this means:

- The Service Bus SDK is built for Service Bus and is not expected to work against RabbitMQ unchanged. This guide has not tested it.
- A general AMQP 1.0 client could talk to both brokers, with the address and authentication differences handled in configuration. That would replace two broker-specific implementations with one, at the cost of Service Bus SDK features such as lock renewal and dead-letter handling.
- The sample uses RabbitMQ's 0-9-1 client, which is why the table above shows 0-9-1.

## Authentication options

1. **Password.** The recipe generates a username and password. Radius stores them in a Kubernetes Secret, and the application binds them as environment variables.
2. **OAuth 2.0 with your identity provider.** This is the same federated pattern Entra workload identity uses, with your own issuer. Set the issuer on the recipe. The worker sends its projected Kubernetes service account token to the issuer's token endpoint as a client assertion (`client_credentials` grant with a JWT bearer assertion), receives an access token, and presents it to RabbitMQ as the password. No secret is stored: the cluster issues and rotates the service account token. Authorization travels in the token, so RabbitMQ keeps no user record for the workload. The sample uses Keycloak federated with Active Directory. See the [RabbitMQ OAuth 2.0 guide](https://www.rabbitmq.com/docs/oauth2).

## Gaps in the reference recipe

The sample recipe is a starting point, not a production broker. Check these before relying on it:

- **No data volume.** Queues and messages are declared durable, but nothing persists the broker's data directory, so messages are lost if the pod is rescheduled.
- **Single pod.** The recipe does not set replicas or a clustered queue type.
- **No dead-lettering.** The queue type's `maxDeliveryCount` setting is not applied by this recipe.
- **No TLS on the AMQP listener.**
- **Management interface** is exposed on its own port and still uses the generated password.

## Running it where Azure is not reachable

For disconnected operations, the recipe takes a registry address and an image pull secret, so the RabbitMQ image and the recipe itself come from your local registry. Mirror both before the disruption, and pin their versions.

## Code impact

- A RabbitMQ implementation of the publish and subscribe interfaces, with its own acknowledge, retry and reconnect behaviour.
- A selector that chooses the implementation from the `provider` value.
- With OAuth, a small token provider that reads the projected service account token and refreshes access tokens.

## Validation

| Target | Pack | Platform | RabbitMQ | Result |
|---|---|---|---|---|
| Azure Local (connected) | `<pack version>` | `<Azure Local build>` | 4 (`4-management-alpine`) | `<to confirm>` |
| Azure Local (disconnected) | `<pack version>` | `<ALDO build>` | 4 (`4-management-alpine`) | `<to confirm>` |

## References

- [RabbitMQ AMQP 1.0 support](https://www.rabbitmq.com/docs/amqp)
- [RabbitMQ OAuth 2.0 authentication and authorization](https://www.rabbitmq.com/docs/oauth2)
- [RabbitMQ persistence configuration](https://www.rabbitmq.com/docs/persistence-conf)
- [AMQP 1.0 in Azure Service Bus](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-amqp-overview)
- [AMQP 1.0 protocol guide for Azure Service Bus](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-amqp-protocol-guide)
- [Service Bus dead-letter queues](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues)
