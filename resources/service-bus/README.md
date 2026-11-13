# Azure Service Bus → Azure Local

Azure Service Bus isn't available on Azure Local. This guide describes the alternatives this project explored, what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [RabbitMQ](./alternatives/rabbitmq.md) | `adapter-required` | Sample available | Open-source broker (MPL-2.0) you run in the cluster, as a three-node cluster with the RabbitMQ operators or as a single broker. Different client and failure handling, so the application talks to it through an adapter. |

## What stayed the same in the sample

- **The queue semantics the sample uses:** send, receive, acknowledge, redeliver on failure, dead-letter after a maximum number of deliveries.
- **Messages:** JSON payloads, message ID, content type and message type, and trace context in the message's properties.
- **Business logic:** the sample's message handlers didn't change.
- **Encrypted, verified connections:** Service Bus always uses TLS. The sample's RabbitMQ accepts TLS only, with a certificate the client checks.
- **Secret-free sign-in:** on Azure the sample uses Entra workload identity federation. On Azure Local it stayed secret-free: RabbitMQ's OAuth 2.0 plugin accepts tokens from Keycloak, which trusts the cluster's service account tokens the way Entra does. Only the token issuer changed. An app that connects with a shared access key instead would use a RabbitMQ username and password, which is still a stored secret. The sample didn't test that path.

## What the sample needed to change

1. **One interface for the broker.** The sample moved its Service Bus calls into one class behind an interface, so the rest of the code doesn't depend on either broker.
2. **A RabbitMQ version of that class.** It uses the RabbitMQ client library. The class handles acknowledgements, retries and reconnecting, which the Service Bus SDK did before.
3. **The class chosen at startup** from configuration, so the same image runs on both targets.
4. **Handlers safe to run twice.** Both brokers can deliver a message again, so the sample stores orders and reserves stock in a way that ignores a repeated order.
5. **Sign-in to the broker.** On Azure Local each service gets an access token from Keycloak and passes it to RabbitMQ.
6. **RabbitMQ run in the cluster.** The sample runs it with the RabbitMQ operators, which set up replicas, storage, dead-lettering and TLS. Patching, scaling and monitoring are left to whoever runs the site.

How Service Bus features map to RabbitMQ, and the sample's code for each step: [RabbitMQ as an alternative](./alternatives/rabbitmq.md).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Messaging](https://learn.microsoft.com/azure/architecture/guide/technology-choices/messaging) | Not a drop-in replacement: the Service Bus SDK doesn't work against RabbitMQ. Sessions, scheduled messages and duplicate detection have no built-in equivalent. Dead-lettering and a maximum delivery count need a quorum queue with a dead-letter policy, and the application has to count failed attempts itself. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | Entra ID isn't available on site. The secret-free flow works only with an identity provider on site (Keycloak in the sample) through RabbitMQ's OAuth 2.0 plugin. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The broker is hosted, patched and scaled on site. The sample runs three nodes by default, with every queue copied to each node, so losing a node loses no message. Copies aren't backups. The sample doesn't use Azure Local's [local availability zones](https://learn.microsoft.com/azure/azure-local/concepts/rack-aware-cluster-overview), which rack aware clusters and disaggregated deployments offer. With a single broker, the queue stops while its pod restarts. |

**Data:** messages waiting in Service Bus don't move to RabbitMQ. They have to be processed, or drained, before switching.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) runs the same API and processor against Service Bus on Azure and RabbitMQ on Azure Local. RabbitMQ runs as three nodes by default, or as a single broker. [RabbitMQ as an alternative](./alternatives/rabbitmq.md#how-the-order-management-sample-does-it) links the code for each change above.
