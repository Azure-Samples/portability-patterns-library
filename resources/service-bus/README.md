# Azure Service Bus → Azure Local

Azure Service Bus isn't available on Azure Local. This guide shows what you can use instead, what stays the same, and what you change in your workload.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [RabbitMQ](./alternatives/rabbitmq.md) | `adapter-required` | Sample available | Open-source broker you run in the cluster. Different client and failure handling, so the application talks to it through an adapter. |
| Azure Local | [Apache Kafka](https://kafka.apache.org/documentation/) | — | Documentation available | Not evaluated by this project. See the linked documentation. |

## What carries over

- **Queue semantics:** send, receive, acknowledge, redeliver on failure.
- **Messages:** JSON payloads, message ID, content type and message type.
- **Business logic:** your message handlers don't change.
- **Authentication model**, depending on how you connect to Service Bus today:
  - **Shared access key (connection string):** becomes a RabbitMQ username and password, kept in a Kubernetes Secret. Still a stored secret.
  - **Entra workload identity federation:** stays secret-free. RabbitMQ's OAuth 2.0 plugin accepts tokens from your own identity provider, which trusts the cluster's service account tokens the way Entra does. Only the token issuer changes.

## What you need to change

1. **Hide the broker behind your own interface.** Define publish and subscribe interfaces in your code and move the Service Bus calls into one implementation of them (an adapter).
2. **Add a RabbitMQ adapter** behind the same interfaces, using the RabbitMQ client library. It handles acknowledgement, retry and reconnection itself.
3. **Choose the adapter at startup** from configuration, not with build flags or separate images.
4. **Make handlers idempotent.** Both brokers can deliver a message twice.
5. **Switch the credential** your adapter uses: a username and password, or an access token from your identity provider, matching how you authenticate today (see above).
6. **Run and operate RabbitMQ** in the cluster: storage, high availability, dead-lettering, TLS and monitoring are yours to set up.

How to map Service Bus features to RabbitMQ, and how the sample does each step: [RabbitMQ as an alternative](./alternatives/rabbitmq.md).

## Observed limitations, by pattern

| Pattern (Microsoft Learn) | Limitation for this resource |
|---|---|
| [Messaging](https://learn.microsoft.com/azure/architecture/guide/technology-choices/messaging) | Not a drop-in replacement: the Service Bus SDK doesn't work against RabbitMQ. Sessions, scheduled messages and duplicate detection have no built-in equivalent. Dead-lettering and a maximum delivery count need RabbitMQ policies or queue arguments. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available. If you use workload identity federation, the same secret-free flow works with your own identity provider (Keycloak in the sample) through RabbitMQ's OAuth 2.0 plugin. If you use a shared access key, use a broker username and password instead. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You host, patch and scale the broker. The sample's broker is a single pod with no data volume, so queued messages are lost if the pod moves. |

**Data:** messages waiting in Service Bus don't move to RabbitMQ. Drain the queue before you switch.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) runs the same API and processor against Service Bus on Azure and RabbitMQ on Azure Local. [RabbitMQ as an alternative](./alternatives/rabbitmq.md#how-the-order-management-sample-does-it) points to the code for each step above.
