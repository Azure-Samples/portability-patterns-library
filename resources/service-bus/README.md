# Azure Service Bus → Azure Local

Azure Service Bus isn't available on Azure Local. This guide shows what you can use instead, what stays the same, and what you change in your workload.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [RabbitMQ](./alternatives/rabbitmq.md) | `adapter-required` | Sample available | Open-source broker (MPL-2.0) you run in the cluster, as a three-node cluster with the RabbitMQ operators or as a single broker. Different client and failure handling, so the application talks to it through an adapter. |

## What carries over

- **Queue semantics:** send, receive, acknowledge, redeliver on failure, dead-letter after a maximum number of deliveries.
- **Messages:** JSON payloads, message ID, content type and message type, and trace context in the message's properties.
- **Business logic:** your message handlers don't change.
- **Encrypted, verified connections:** Service Bus always uses TLS; RabbitMQ can accept TLS only, with a certificate the client checks.
- **Authentication model**, depending on how you connect to Service Bus today:
  - **Shared access key (connection string):** becomes a RabbitMQ username and password, kept in a Kubernetes Secret. Still a stored secret.
  - **Entra workload identity federation:** stays secret-free. RabbitMQ's OAuth 2.0 plugin accepts tokens from your own identity provider, which trusts the cluster's service account tokens the way Entra does. Only the token issuer changes.

## What you need to change

1. **Put the broker behind your own interface.** Move the Service Bus calls into one class that implements it.
2. **Add a RabbitMQ version of that class.** Use the RabbitMQ client library. Your code handles acknowledgements, retries and reconnecting.
3. **Pick the class at startup** from configuration. Use the same image on both targets.
4. **Make message handlers safe to run twice.** Both brokers can deliver the same message again.
5. **Change how the app signs in to the broker.** Use a username and password, or an access token from your own identity provider.
6. **Run RabbitMQ yourself.** You set up replicas, storage, dead-lettering, TLS and monitoring. A Kubernetes operator can do most of this.

How to map Service Bus features to RabbitMQ, and how the sample does each step: [RabbitMQ as an alternative](./alternatives/rabbitmq.md).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Messaging](https://learn.microsoft.com/azure/architecture/guide/technology-choices/messaging) | Not a drop-in replacement: the Service Bus SDK doesn't work against RabbitMQ. Sessions, scheduled messages and duplicate detection have no built-in equivalent. Dead-lettering and a maximum delivery count need a quorum queue with a dead-letter policy, and the application has to count failed attempts itself. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available. If you use workload identity federation, the same secret-free flow works with your own identity provider (Keycloak in the sample) through RabbitMQ's OAuth 2.0 plugin. If you use a shared access key, use a broker username and password instead. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You host, patch and scale the broker. The sample runs three nodes by default, with every queue copied to each node, so losing a node loses no message. Copies aren't backups, and Azure Local has no availability zones. With a single broker, the queue stops while its pod restarts. |

**Data:** messages waiting in Service Bus don't move to RabbitMQ. Drain the queue before you switch.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) runs the same API and processor against Service Bus on Azure and RabbitMQ on Azure Local. RabbitMQ runs as three nodes by default, or as a single broker. [RabbitMQ as an alternative](./alternatives/rabbitmq.md#how-the-order-management-sample-does-it) points to the code for each step above.
