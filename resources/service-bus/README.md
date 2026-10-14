# Azure Service Bus → Azure Local

> **Draft sample guide.** Written from the Order Management sample to show the format. Maturity, versions and Microsoft Learn pattern links are placeholders until confirmed.

| Target | Alternative | Status | Class | Maturity | Summary |
|---|---|---|---|---|---|
| Azure Local (connected) | [RabbitMQ](./alternatives/rabbitmq.md) | Requires changes | `adapter-required` | Validated | Self-hosted broker with its own addressing, authentication and failure handling; the application needs a RabbitMQ client behind its queue interface. |
| Azure Local (disconnected, ALDO) | [RabbitMQ](./alternatives/rabbitmq.md) | Requires changes | `adapter-required` | Validated | Same as connected, with the image and recipe served from your local registry. |

## What carries over

- Point-to-point queue semantics: send, receive, acknowledge, redeliver on failure.
- JSON message payloads and the application's handler logic.
- The Resource Type the application declares, if the application asks for a queue through a portable type and not for Service Bus by name.

## What changes, by pattern

| Pattern (Microsoft Learn) | Limitation for this resource |
|---|---|
| Messaging | RabbitMQ 4.0 and later also speak AMQP 1.0 natively, but addressing, authentication and management operations are broker-specific, so the Service Bus SDK is not a drop-in client. The sample uses RabbitMQ's own AMQP 0-9-1 client. You host, patch and monitor the broker. Dead-lettering, lock duration and delivery counts are not provided automatically. |
| Identity | Entra workload identity itself is not available. The same federated, secret-free pattern works through OAuth 2.0 with your own identity provider (Keycloak in the sample). The fallback is a generated password. |
| Storage | A single broker pod with no data volume loses queued messages if it is rescheduled. Production use needs persistent storage and a clustered or quorum setup. |

## Code impact

A second broker implementation behind the same publish and subscribe interfaces, plus code to choose it at startup. In the sample the worker logic is unchanged. Details are in the [RabbitMQ page](./alternatives/rabbitmq.md).

## Data

Messages waiting in Service Bus are not carried to the new broker. Data migration is separate guidance.

## Examples

The Order Management sample runs the same workers against Service Bus on Azure and RabbitMQ on Azure Local. It will be added under `samples/order-management`.
