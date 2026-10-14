# Portable Apps Library — Proposal

> **Status:** Draft for review.

## 1. Purpose

Business-continuity assessments will tell a customer which Azure resources in their subscription can move to Azure Local (connected), Azure Local disconnected operations (ALDO) or another Kubernetes platform, and which need changes. This repository is where they go next. For each Azure resource it explains **what carries over, what changes and what the alternatives are**, backed by sample applications tested on Azure, Azure Local and ALDO.

It supports the scenario *Redeploy from Sovereign Public Cloud to Sovereign Private Cloud*: same container images, same application definition, only the infrastructure changes, with documented degradations.

## 2. Name

**Recommendation: `portable-apps-library`.** This repository is currently named `portability-patterns-library`. The name should cover guidance, reusable recipes and runnable samples, not one target or one scenario.

| Candidate | Assessment |
|---|---|
| `portable-apps-library` | **Recommended.** Describes the outcome and fits guides, recipes and samples. |
| `portability-patterns-library` | Current name. Reads as documentation only; understates recipes and samples. |
| `business-continuity-library` | Ties the repository to one scenario; portability also serves sovereignty and edge. |

## 3. Building blocks

The library builds on [Radius](https://docs.radapp.io/), the open-source application platform the Order Management sample uses to switch environments without changing the app. Resource Type, Recipe and Recipe Pack are Radius terms.

| Block | What it is | Example |
|---|---|---|
| **Resource Type** | What the app needs, independent of any product. | `objectStorage` |
| **Recipe** | How one platform provides it. | Azurite; RabbitMQ |
| **Recipe Pack** | All recipes for one environment. | `azure-local-disconnected` |
| **Sample** | An app that combines several resources. | Order Management System |
| **Resource guide** | One page per Azure resource: what works, what changes, alternatives. | `resources/service-bus/` |

In this document, a **resource** means an Azure resource, because the Azure portal shows business continuity per resource. It is not a Radius Resource Type, which describes what an app needs.

The application asks for a Resource Type; the environment's Recipe Pack picks the Recipe that provides it.

Principles:

- **Reuse before inventing.** Add a new Resource Type only for a real gap.
- **Pin releases, treat packs as reference baselines.** Customers use a tagged release, never `main`. Identity, networking, HA, storage, certificates and capacity stay customer-specific.
- **Recipes cannot hide a missing capability** (for example no local object service in ALDO). The guide states the compromise.

### Who provides what

A Recipe Pack creates no infrastructure itself; it only lists which Recipes an environment uses. Recipes then create the application's dependencies (SQL, queue, object storage, secrets): as Azure services in the Azure pack, or as self-hosted services **in a cluster that already exists** in the Azure Local packs. Creating that cluster differs per environment, so it stays with the customer.

| Layer | Examples | Provided by |
|---|---|---|
| **Platform**, once per site | Azure Local instance, AKS or AKS Arc cluster, Radius, ingress and certificates, local registry, identity provider (AD, Keycloak) | **Customer.** The library lists the prerequisites on the `targets/` page. The sample includes reference setup scripts, marked as such. |
| **Dependencies**, per environment | SQL, queue, object storage, secrets | **Library:** Recipes, selected by the Recipe Pack. |
| **Application** | Container images, application definition | **Customer.** |

## 4. Structure

```text
portable-apps-library/
├── README.md                                 # Catalog of all resources + getting started
├── CONTRIBUTING.md
├── catalog/                                  # schema.json + generated resources.json
├── resources/                                # One folder per Azure resource
│   └── <slug>/                               # e.g. service-bus, blob-storage, postgresql
│       ├── README.md                         # Guide (stable URL)
│       ├── facts.yaml                        # Machine-readable facts
│       ├── alternatives/                     # One page per alternative
│       └── examples/                         # Smallest single-resource deployment per target
├── targets/                                  # One page per target environment
├── recipes/                                  # <capability>/<platform>/<implementation>
│   └── object-storage/azure-local/azurite/   # recipe .bicep, README.md, test/app.bicep
├── recipe-packs/                             # One pack per environment, e.g. azure-local-disconnected
└── samples/                                  # End-to-end apps, e.g. order-management
```

| Folder | Purpose |
|---|---|
| `resources/<slug>/examples/` | The **smallest** deployment of that one resource on each target. For SQL: a tiny app that writes and reads one row, with no queue or backend. Where a recipe exists this is the recipe's `test/app.bicep`; link to it, do not copy it. |
| `samples/` | Complete multi-resource apps that prove identity, messaging, storage and SQL work **together** across targets. The business-continuity demo runs from here. |
| `targets/` | One page per environment (Azure Local connected, ALDO, Kubernetes): **what the customer must already have** (cluster, local registry, identity provider, ingress, observability, capacity); **how it differs from Azure** (connectivity, identity model, what works offline); which recipe pack to use and the setup order; a status table of every resource on that target. |

## 5. Resource guide

Every Azure resource has one guide, `resources/<slug>/README.md`, at a stable URL. The Azure portal shows business continuity per resource, so the guides follow the same unit: one guide for Service Bus, one for Blob Storage, and so on, not one per Radius Resource Type. A guide summarizes the resource across all targets and alternatives, and links to `alternatives/` and `examples/` for detail.

An **alternative** is how you get the capability on a target. It can be a different product (Service Bus on RabbitMQ), the same engine hosted by you (SQL Server in a container), or the Azure service itself where it is still reachable.

Illustrative example (not final content):

> ### Azure Service Bus → Azure Local
>
> | Target | Alternative | Status | Class | Maturity | Summary |
> |---|---|---|---|---|---|
> | Azure Local (connected) | RabbitMQ | Requires changes | `adapter-required` | Validated | Self-hosted broker; review protocol, identity and feature differences. |
> | Azure Local (connected) | Kafka | Requires changes | `adapter-required` | Documented | Self-hosted Kafka; topic model differs from queues and needs more application change. |
> | Azure Local (disconnected, ALDO) | RabbitMQ | Requires changes | `adapter-required` | Validated | Self-hosted broker from your local registry; review protocol, identity and feature differences. |
>
> **What carries over:** queue semantics, message payloads, application logic.
>
> **What changes, by pattern:**
>
> | Pattern (Microsoft Learn) | Limitation for this resource |
> |---|---|
> | Messaging | AMQP 1.0 becomes AMQP 0-9-1 (RabbitMQ); you host and operate the broker. |
> | Identity | Entra workload identity is unavailable; use broker credentials or OAuth through Keycloak. |
>
> **Code impact:** a small messaging adapter.
> **Data:** queued messages are not carried over; data migration is separate guidance.
> **Examples tried:** `examples/rabbitmq/`, `samples/order-management`.

**Patterns:** a resource often touches several patterns (SQL: database and identity). The guide lists each affected pattern with this resource's limitation and a link to the pattern on Microsoft Learn, without restating it.

`facts.yaml` holds the same facts in machine-readable form. It is the single source for the guide's table and, later, the Azure portal, which shows the alternatives for the customer's chosen target:

```yaml
azureResourceType: Microsoft.ServiceBus/namespaces
slug: service-bus
lastReviewed: 2026-10-14
targets:
  azure-local-disconnected:
    alternatives:
      - id: rabbitmq                  # matches alternatives/rabbitmq.md
        status: requires-changes
        portabilityClass: adapter-required
        summary: Self-hosted broker from your local registry; review protocol, identity and feature differences.
        maturity: validated
        validatedWith: { pack: 0.1.0, platform: <ALDO build>, software: RabbitMQ 4 }
      - id: kafka
        status: requires-changes
        portabilityClass: adapter-required
        summary: Self-hosted Kafka; topic model differs from queues and needs more application change.
        maturity: documented
  # azure-local-connected: same shape
```

The same shape covers a resource that needs no different product. For SQL the alternative is the same engine, hosted by you (another entry under `alternatives:`):

```yaml
      - id: sql-server-container
        status: requires-changes
        portabilityClass: protocol-compatible
        summary: Same engine (TDS), self-hosted; you operate it and use SQL authentication.
        maturity: validated
        validatedWith: { pack: 0.1.0, platform: <ALDO build>, software: SQL Server 2022 }
```

Conventions:
- **No workable option:** a single entry with `id: none` and `status: no-viable-path`, with the reason in `summary`.
- **`validatedWith`** records the recipe pack version, the platform build and the `software` version that was run. The software version matters when a pack does not pin it.

### Labels used in a guide

The values above. Status, class, summary and maturity are set per alternative on each target; the resource identity and review date are shared.

**Status** (can it move to this target?): `portable` moves with configuration changes only; `requires-changes` can move but needs application, identity or operations changes; `no-viable-path` has no workable option.

**Portability class**: what kind of change is needed?

| Value | Meaning | Example |
|---|---|---|
| `protocol-compatible` | Same protocol or API on the target; endpoint, identity and operations change. | PostgreSQL; SQL Server |
| `adapter-required` | Protocols or features differ; small app change needed. | Service Bus (AMQP 1.0) → RabbitMQ |
| `no-equivalent` | Nothing comparable on the target; redesign or customer-operated alternative. | Object storage in ALDO (no local service); virtual networks |

**Maturity**: how much have we verified it on this target? A lab deployment never implies production support.

| Value | Meaning |
|---|---|
| `validated` | The scripted example or sample was deployed on that target and worked. `validatedWith` records what it ran on. |
| `documented` | Based on product documentation or analysis; not run on that target. |

**Origin** (optional): `community` marks an alternative contributed from outside the team. It is separate from maturity, because community content can be validated or only documented.

## 6. Portal routing

| Option | Pros | Cons |
|---|---|---|
| **A. Link to the resource page** (`/resources/service-bus/`) | Lands on the answer; stable slug survives rewrites; link-checkable. | One URL per resource. |
| B. Anchor on the top-level page (`/#service-bus`) | Single page. | Anchors break on heading rename; long page; poor landing. |

**Recommendation: A.** The portal stores the slug or URL. The top-level page is for browsing, not routing. A renamed slug keeps a redirect.

**Future:** CI generates `catalog/resources.json` from the `facts.yaml` files and the portal consumes the released file for its messages. This needs an agreed schema version, release cadence and wording owner first.

## 7. Testing and release

- **Done means:** guide + `facts.yaml` + references + documented compromises + a runnable example. Without a run on that target, the maturity is `documented`.
- **Testing:**
  - Public CI deploys each recipe's `test/app.bicep` and each pack on Kubernetes.
  - Azure Local and ALDO cannot run in public CI. A `validated` label there means the scripted example or sample was deployed on that target, with the recipe pack version, platform build and software version recorded in `facts.yaml` (`validatedWith`). No logs are stored; the deployment is scripted, so anyone can re-run it.
  - Anything not run on that target is labelled `documented` instead. A `validated` label is re-checked when the pack, platform or software version changes, or when `lastReviewed` lapses.
- **Releases:** independent semantic-version tags per recipe and per pack. Recipes are published as OCI artifacts; disconnected users mirror them to a local registry.

## 8. First increment

1. Guides and `facts.yaml` for the eight assessed resources: PostgreSQL, SQL, Blob Storage, Azure Files, Service Bus, Key Vault, Log Analytics, Virtual Network.
2. Promote the Order Management sample (branch `azure-local-hybrid-demo`) to `samples/order-management`.
3. Recipes (queue, object storage, SQL) and packs for Azure, Azure Local connected and ALDO, with matching `targets/` pages.
4. Defer portal ingestion until schema and ownership are agreed.

## 9. Open questions

1. Is **Portable Apps Library** the right name, and which organization hosts it?
2. Do recipes live here, or in the Radius community repository (`resource-types-contrib`) wherever a Resource Type already exists?
3. Which queue abstraction do we standardize on: the custom type used in the sample (`BusinessContinuity.Messaging/messageQueues`), or an existing Radius type?
4. Section 3 assumes recipe packs are reference baselines. Do we confirm that, or position them as a supported product?
5. Who owns the `facts.yaml` wording shown in the Azure portal, and what is the review SLA?
6. The Radius recipe-pack model is preview. Do we pin a Radius version and accept churn?
