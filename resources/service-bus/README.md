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
- **Secret-free authentication:** the pod's Kubernetes token is exchanged for an access token on both targets. Only the issuer changes: Entra ID on Azure, your own identity provider on Azure Local.

## What you need to change

1. **Hide the broker behind your own interface.** Define publish and subscribe interfaces in your code and move the Service Bus calls into one implementation of them (an adapter).
2. **Add a RabbitMQ adapter** behind the same interfaces, using the RabbitMQ client library. It handles acknowledgement, retry and reconnection itself.
3. **Choose the adapter at startup** from configuration, not with build flags or separate images.
4. **Make handlers idempotent.** Both brokers can deliver a message twice.
5. **Replace Entra authentication** with OAuth 2.0 tokens from your identity provider, or with a broker username and password.
6. **Run and operate RabbitMQ** in the cluster: storage, high availability, dead-lettering, TLS and monitoring are yours to set up.

How to map Service Bus features to RabbitMQ, and how the sample does each step: [RabbitMQ as an alternative](./alternatives/rabbitmq.md).

## Observed limitations, by pattern

| Pattern (Microsoft Learn) | Limitation for this resource |
|---|---|
| [Messaging](https://learn.microsoft.com/azure/architecture/guide/technology-choices/messaging) | Not a drop-in replacement: the Service Bus SDK doesn't work against RabbitMQ. Sessions, scheduled messages and duplicate detection have no built-in equivalent. Dead-lettering and a maximum delivery count need RabbitMQ policies or queue arguments. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra workload identity isn't available. The same federated, secret-free flow works with your own identity provider (Keycloak in the sample) through RabbitMQ's OAuth 2.0 plugin. Otherwise use a broker password. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You host, patch and scale the broker. The sample's broker is a single pod with no data volume, so queued messages are lost if the pod moves. |

**Data:** messages waiting in Service Bus don't move to RabbitMQ. Drain the queue before you switch.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) runs the same API and processor against Service Bus on Azure and RabbitMQ on Azure Local. [RabbitMQ as an alternative](./alternatives/rabbitmq.md#how-the-order-management-sample-does-it) points to the code for each step above.
