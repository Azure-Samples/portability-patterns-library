# Portable Apps Library — Proposal

> **Status:** Draft for review. Optional background: [portable-apps-library-validation.md](./portable-apps-library-validation.md).

## 1. Purpose

Business-continuity assessments will tell a customer which Azure resources in their subscription can move to Azure Local (connected), Azure Local disconnected operations (ALDO) or another Kubernetes platform, and which need changes. This repository is where they go next. For each Azure resource it explains **what carries over, what changes and what the alternatives are**, backed by sample applications tested on Azure, Azure Local and ALDO.

It supports the scenario *Redeploy from Sovereign Public Cloud to Sovereign Private Cloud*: same container images, same application definition, only the infrastructure changes, with documented degradations.

## 2. Name

**Recommendation: `portable-apps-library`.** The name should cover guidance, reusable recipes and runnable samples, not one target or one scenario.

| Candidate | Assessment |
|---|---|
| `portable-apps-library` | **Recommended.** Describes the outcome and fits guides, recipes and samples. |
| `portability-patterns-library` | Reads as documentation only; understates recipes and samples. |
| `business-continuity-library` | Ties the repository to one scenario; portability also serves sovereignty and edge. |

## 3. Building blocks

The library builds on [Radius](https://docs.radapp.io/), the open-source application platform the sample uses to switch environments without changing the app. Resource Type, Recipe and Recipe Pack are Radius terms.

| Block | What it is | Example |
|---|---|---|
| **Resource guide** | One page per Azure resource: what works, what changes, alternatives. | `resources/service-bus/` |
| **Resource Type** | What the app needs, independent of any product. | `objectStorage` |
| **Recipe** | How one platform provides it. | Azurite; RabbitMQ |
| **Recipe Pack** | All recipes for one environment. | `azure-local-disconnected` |
| **Sample** | An app that combines several resources. | Order Management System |

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
├── README.md                          # Catalog of all resources + getting started
├── CONTRIBUTING.md
├── catalog/                           # schema.json + generated resources.json
├── resources/<azure-resource-slug>/   # service-bus, blob-storage, postgresql, ...
│   ├── README.md                      # Guide (stable URL)
│   ├── facts.yaml                     # Machine-readable facts
│   ├── alternatives/                  # One page per alternative
│   └── examples/                      # Smallest single-resource deployment per target
├── targets/                           # One page per target environment
├── types/<Category>/<typeName>/       # Only when no existing Resource Type fits:
│                                      #   <typeName>.yaml, README.md, recipes/<platform>/, test/app.bicep
├── recipe-packs/                      # azure, azure-local-connected,
│                                      #   azure-local-disconnected, kubernetes
└── samples/order-management/          # Promoted from BusinessContinuityDemoApp
```

| Folder | Purpose |
|---|---|
| `resources/<slug>/examples/` | The **smallest** deployment of that one resource on each target. For SQL: a tiny app that writes and reads one row, with no queue or backend. Where a Resource Type exists this is its `test/app.bicep`; link to it, do not copy it. |
| `samples/` | Complete multi-resource apps that prove identity, messaging, storage and SQL work **together** across targets. The business-continuity demo runs from here. |
| `targets/` | One page per environment (Azure Local connected, ALDO, Kubernetes): **what the customer must already have** (cluster, local registry, identity provider, ingress, observability, capacity); **how it differs from Azure** (connectivity, identity model, what works offline); which recipe pack to use and the setup order; a status table of every resource on that target. |

## 5. Resource guide

Every resource has one guide, `resources/<slug>/README.md`, at a stable URL. It summarizes the resource across all targets, with one status row per target, and links to `alternatives/` and `examples/` for detail.

Illustrative example (not final content):

> ### Azure Service Bus → Azure Local
>
> | Target | Status | Class | Maturity | Summary |
> |---|---|---|---|---|
> | Azure Local (connected) | Requires changes | `adapter-required` | Tested | No Service Bus equivalent; use a self-hosted broker and review protocol, identity and feature differences. |
> | Azure Local (disconnected, ALDO) | Requires changes | `adapter-required` | Tested | No Service Bus equivalent; use a self-hosted broker from your local registry and review protocol, identity and feature differences. |
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
> **Alternatives:** RabbitMQ (tested), Kafka (documented).
> **Examples tried:** `examples/rabbitmq/`, `samples/order-management`.

**Patterns:** a resource often touches several patterns (SQL: database and identity). The guide lists each affected pattern with this resource's limitation and a link to the pattern on Microsoft Learn, without restating it.

`facts.yaml` holds the same facts in machine-readable form. It is the single source for the guide's table and, later, the Azure portal, which shows the entry for the customer's chosen target:

```yaml
azureResourceType: Microsoft.ServiceBus/namespaces
slug: service-bus
targets:
  azure-local-connected:
    status: requires-changes
    portabilityClass: adapter-required
    summary: >-
      No Service Bus equivalent; use a self-hosted broker and review protocol,
      identity and feature differences.
    alternatives: [rabbitmq, kafka]
    maturity: tested
    testedWith: { pack: 0.1.0, platform: <Azure Local build> }
  azure-local-disconnected:
    status: requires-changes
    portabilityClass: adapter-required
    summary: >-
      No Service Bus equivalent; use a self-hosted broker from your local registry and
      review protocol, identity and feature differences.
    alternatives: [rabbitmq, kafka]
    maturity: tested
    testedWith: { pack: 0.1.0, platform: <ALDO build> }
lastReviewed: 2026-10-14
owner: <team-alias>
```

### Labels used in a guide

The values above. Everything under a target (status, class, summary, alternatives, maturity) is set per target; only the resource identity, review date and owner are shared.

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
| `tested` | The scripted example or sample was deployed on that target and worked. `testedWith` records the recipe pack version and platform build it worked on. |
| `documented` | Based on product documentation or analysis; not run on that target. |
| `preview` | Depends on a target feature that is itself in preview, so it may change. |
| `community` | Contributed from outside the team; not verified by us. |

## 6. Portal routing

| Option | Pros | Cons |
|---|---|---|
| **A. Link to the resource page** (`/resources/service-bus/`) | Lands on the answer; stable slug survives rewrites; link-checkable. | One URL per resource. |
| B. Anchor on the top-level page (`/#service-bus`) | Single page. | Anchors break on heading rename; long page; poor landing. |

**Recommendation: A.** The portal stores the slug or URL. The top-level page is for browsing, not routing. A renamed slug keeps a redirect.

**Future:** CI generates `catalog/resources.json` from the `facts.yaml` files and the portal consumes the released file for its messages. This needs an agreed schema version, release cadence and wording owner first.

## 7. Testing and release

- **Done means:** guide + `facts.yaml` + owner + references + documented compromises + a runnable example. Without a run on that target, the maturity is `documented`.
- **Testing:**
  - Public CI deploys each type's `test/app.bicep` and each pack on Kubernetes.
  - Azure Local and ALDO cannot run in public CI. A `tested` label there means the scripted example or sample was deployed on that target, with the recipe pack version and platform build recorded in `facts.yaml` (`testedWith`). No logs are stored; the deployment is scripted, so anyone can re-run it.
  - Anything not run on that target is labelled `documented` instead. A `tested` label is re-checked when the pack or platform version changes, or when `lastReviewed` lapses.
- **Releases:** independent semantic-version tags per type and per pack. Recipes are published as OCI artifacts; disconnected users mirror them to a local registry.

## 8. First increment

1. Guides and `facts.yaml` for the eight assessed resources: PostgreSQL, SQL, Blob Storage, Azure Files, Service Bus, Key Vault, Log Analytics, Virtual Network.
2. Promote the Order Management sample (branch `azure-local-hybrid-demo`) to `samples/order-management`.
3. Packs for Azure, Azure Local connected and ALDO, with matching `targets/` pages.
4. Defer portal ingestion until schema and ownership are agreed.

## 9. Open questions

1. Is **Portable Apps Library** the right name, and which organization hosts it?
2. Do recipes live here, or in the Radius community repository (`resource-types-contrib`) wherever a Resource Type already exists?
3. Which queue abstraction do we standardize on: the custom type used in the sample, or an existing Radius type?
4. Section 3 assumes recipe packs are reference baselines. Do we confirm that, or position them as a supported product?
5. Who owns the `facts.yaml` wording shown in the Azure portal, and what is the review SLA?
6. The Radius recipe-pack model is preview. Do we pin a Radius version and accept churn?
