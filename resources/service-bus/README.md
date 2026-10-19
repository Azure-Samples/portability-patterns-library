# Azure Service Bus → Azure Local

> **Draft sample guide**, written from the Order Management sample.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [RabbitMQ](./alternatives/rabbitmq.md) | `adapter-required` | Sample available | Self-hosted broker with its own addressing, authentication and failure handling. |
| Azure Local | [Apache Kafka](https://kafka.apache.org/documentation/) | — | Documentation available | Not evaluated by this project. See the linked documentation. |

## What carries over

- Point-to-point queue semantics: send, receive, acknowledge, redeliver on failure.
- JSON message payloads and the application's handler logic.
- The Resource Type the application declares, if the application asks for a queue through a portable type and not for Service Bus by name.

## Required application changes

A second broker implementation behind the same publish and subscribe interfaces, plus code to choose it at startup. In the sample the worker logic is unchanged. Details are in the [RabbitMQ page](./alternatives/rabbitmq.md).

## Observed limitations, by pattern

| Pattern (Microsoft Learn) | Limitation for this resource |
|---|---|
| Messaging | RabbitMQ 4.0+ also speaks AMQP 1.0, but addressing, authentication and management are broker-specific, so the Service Bus SDK is not a drop-in client. The sample uses RabbitMQ's own AMQP 0-9-1 client. The broker is hosted, patched and monitored by the customer. Dead-lettering, lock duration and delivery counts are not provided automatically. |
| Identity | Entra workload identity itself is not available. The same federated, secret-free pattern works through OAuth 2.0 with the customer's own identity provider (Keycloak in the sample). The alternative is a generated password. |
| Storage | The reference recipe does not mount a data volume, so queued messages are lost if the broker pod is rescheduled. |

## Data

Messages waiting in Service Bus are not carried to the new broker.

## Examples

The Order Management sample runs the same workers against Service Bus on Azure and RabbitMQ on Azure Local.
