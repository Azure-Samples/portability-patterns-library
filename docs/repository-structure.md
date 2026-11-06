# Repository structure

## 1. Purpose

This repository hosts samples and references for running Azure workloads on Azure Local. For each Azure resource it describes what carries over, what changes and which alternatives were evaluated, with sample applications that run on Azure and Azure Local.

It supports the scenario *Redeploy from Sovereign Public Cloud to Sovereign Private Cloud*: same container images, same application definition, only the infrastructure changes, with documented degradations.

All content is sample and reference material. Customers remain responsible for their production implementation and operation.

## 2. Building blocks

The samples build on [Radius](https://docs.radapp.io/), an open-source application platform that lets the same application definition run in different environments. Resource Type, Recipe and Recipe Pack are Radius terms.

| Block | What it is | Example |
|---|---|---|
| **Resource Type** | What the app needs, independent of any product. | `objectStorage` |
| **Recipe** | How one platform provides it. | Azurite; RabbitMQ |
| **Recipe Pack** | All recipes for one environment. | `azure-local` |
| **Sample** | An app that combines several resources. | Order Management System |
| **Resource guide** | One page per Azure resource: what carries over, what changes, alternatives evaluated. | `resources/service-bus/` |

The application asks for a Resource Type; the environment's Recipe Pack picks the Recipe that provides it.

In this document, a **resource** means an Azure resource. It is not a Radius Resource Type, which describes what an app needs.

### Responsibility

The repository provides samples and references. Customers remain responsible for production implementation and operation.

| Building block | What this repository provides | Production responsibility |
|---|---|---|
| Infrastructure | Sample scripts and official documentation references | Customer |
| Recipes and recipe packs | Sample source | Customer |
| Application | Sample application | Customer |

### Infrastructure scope

- Infrastructure automation, such as scripts that set up Azure Local, AKS, Radius, ingress, a registry or identity, is sample code. It is not official or prescriptive deployment guidance.
- For any prerequisites and environment setup, see the official Microsoft documentation: [Azure Local](https://learn.microsoft.com/en-us/azure/azure-local/), [AKS enabled by Azure Arc](https://learn.microsoft.com/en-us/azure/aks/aksarc/) and [Radius](https://docs.radapp.io/).
- Customers must adapt the samples to their environment, tools, security requirements and production standards.

## 3. Structure

```text
portability-patterns-library/
├── README.md
├── resources/                                # One folder per Azure resource
│   └── <slug>/                               # e.g. service-bus, blob-storage, postgresql
│       ├── README.md                         # Guide
│       ├── alternatives/                     # One page per alternative
│       └── examples/                         # Only when no sample covers the resource
├── targets/                                  # One page per target environment
├── recipes/                                  # <capability>/<platform>/<implementation>
│   └── object-storage/azure-local/azurite/   # Recipe source, README, test app
├── recipe-packs/                             # One pack per environment, e.g. azure-local
└── samples/                                  # End-to-end apps, e.g. OrderManagementApp
```

| Folder | Purpose |
|---|---|
| `resources/<slug>/examples/` | The smallest deployment of that one resource on each target, added only when no sample under `samples/` covers the resource. For SQL: a small app that writes and reads one row, with no queue or backend. When a sample covers the resource, the guide's Examples section links to the sample's Recipes, Recipe Packs and code instead. |
| `samples/` | Multi-resource apps that combine identity, messaging, storage and SQL across targets. The business-continuity demo runs from here. |
| `targets/` | One page per environment (Azure Local, Kubernetes, what works offline): links to the official Microsoft documentation for prerequisites, how the environment differs from Azure (connectivity, identity model), and which recipe pack sample applies. |

## 4. Resource guide

Every Azure resource has one guide, `resources/<slug>/README.md`. It summarizes the resource across all targets and alternatives, and links to `alternatives/` for detail and to a sample or `examples/` for working code.

An **alternative** is how the capability is provided on a target. It can be a different product (RabbitMQ in place of Service Bus), the same engine hosted by the customer (SQL Server in a container), or the Azure service itself where it is still reachable.

The open-source alternatives in a guide are ones this project chose to explore. They aren't recommendations or endorsements by Microsoft, and other alternatives may exist. Guides state what was observed, without ranking or recommending one alternative over another. Each guide says this in a short note under its introduction.

Illustrative example (not final content):

> ### Azure Service Bus → Azure Local
>
> | Target | Alternative | Portability class | Availability | Summary |
> |---|---|---|---|---|
> | Azure Local | [RabbitMQ](./alternatives/rabbitmq.md) | `adapter-required` | Sample available | Self-hosted broker with its own addressing, authentication and failure handling. |
> | Azure Local | [Apache Kafka](https://kafka.apache.org/documentation/) | — | Documentation available | Not evaluated by this project. See the linked documentation. |
>
> **What carries over:** queue semantics, message payloads, application logic.
>
> **Required application changes:** a second broker implementation behind the same publish and subscribe interfaces, and code to choose it at startup.
>
> **Observed limitations:**
>
> | Pattern | Limitation for this resource |
> |---|---|
> | Messaging | RabbitMQ 4.0+ also speaks AMQP 1.0, but addressing, authentication and management are broker-specific, so the Service Bus SDK is not a drop-in client. The broker is hosted and operated by the customer. |
> | Identity | Entra workload identity is unavailable. The same federated token flow works against the customer's own identity provider (Keycloak in the sample), or the broker uses its own credentials. |
>
> **Data:** messages waiting in Service Bus are not carried to the new broker.

**Patterns:** a resource often touches several patterns (SQL: database and identity). The guide lists each affected pattern with the limitation observed for that resource and a link to the pattern on Microsoft Learn.

### Labels used in a guide

**Portability class** describes an observed characteristic of an alternative:

| Value | Meaning | Example |
|---|---|---|
| `protocol-compatible` | Same protocol or API on the target; endpoint, identity and operations change. | PostgreSQL; SQL Server |
| `adapter-required` | Protocols or features differ; a workload change is needed. | Service Bus queues with RabbitMQ |
| `no-equivalent` | Nothing comparable on the target. | Virtual networks |

**Availability** says what this repository contains for an alternative:

| Value | Meaning |
|---|---|
| Sample available | This repository contains a sample that was deployed on the target. The alternative's name in the guide links to its page under `alternatives/`. |
| Documentation available | Only external or Microsoft Learn documentation exists. The alternative's name in the guide links directly to that documentation, and the summary says it was not evaluated by this project. Its portability class is not given. |
