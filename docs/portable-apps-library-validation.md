# Portable Apps Library — Validation Against Radius and Adaptive Apps

> **Optional background** for [portable-apps-library-proposal.md](./portable-apps-library-proposal.md). Checked on 2026-10-13 against:
> [`radius-project/resource-types-contrib`](https://github.com/radius-project/resource-types-contrib), [Radius concepts](https://docs.radapp.io/concepts/), the [Adaptive Apps Learn article](https://learn.microsoft.com/en-us/azure/architecture/solution-ideas/articles/adaptive-apps) and [`microsoft/adaptive-apps`](https://github.com/microsoft/adaptive-apps).
>
> Adaptive Apps is a **separate project**. The Portable Apps Library is part of Business Continuity: testing sample apps on Azure Local and ALDO and giving guidance. The two may collaborate later; this document only records where the proposal aligns with them.

## 1. Findings

| # | Proposal element | Verdict | Evidence | Change made or suggested |
|---|---|---|---|---|
| 1 | Resource Type → Recipe → Recipe Pack layering | **Holds** | Radius: Resource Types are the interface, Recipe Packs the implementation, Environments reference packs. | None. |
| 2 | Resource Types abstract provisioning, not the data plane | **Holds** | Radius: abstract, application-oriented types. Adaptive Apps: avoid new data-plane abstractions; use open protocols (OIDC, MQTT, PostgreSQL), Dapr optional. | Guides carry a portability class (`protocol-compatible`, `adapter-required`, `no-equivalent`). |
| 3 | Recipe Packs as reference baselines | **Holds** | Upstream packs are per platform and compute (`azure-aks`, `azure-aci`, `kubernetes`), declare only a `Radius.Core/recipePacks` resource, and never create Environments. | Packs declare only the pack; Environments live in samples. |
| 4 | Layout | **Adjust** | Upstream co-locates each type's recipes and `test/app.bicep` in one folder: `<Category>/<type>/{<type>.yaml, README.md, recipes/<platform>/, test/app.bicep}`. | For now the library holds only `recipes/<capability>/<platform>/<implementation>/`. A `types/` folder following upstream's layout can be added when a type is contributed upstream. |
| 5 | Pin released versions | **Holds** | Upstream: per-namespace tags `Radius.<Category>/vX.Y.Z`, per-pack releases, signed provenance, recipes as OCI artifacts on GHCR. | Same scheme; disconnected users mirror artifacts locally (done in the `aldo` pack). |
| 6 | Tests and evidence | **Holds** | Upstream CI deploys each pack per PR, validates property mappings statically and runs nightly recipe tests. | Co-locate `test/app.bicep` with each recipe; record Azure Local and ALDO runs, which upstream CI does not cover, in `facts.yaml` (`testedWith`). |
| 7 | Portal deep link and catalog | **No conflict** | Neither project provides per-Azure-resource landing pages or a portal-facing catalog. | None. |
| 8 | Stability | **Risk** | Radius docs mark the Recipe Pack model as preview (`--preview`, `Radius.Core/recipePacks@2025-08-01-preview`). | Record the tested Radius version; expect churn. |

## 2. Existing Resource Types versus the eight assessed resources

Check these first; add a new Resource Type only for a real gap. *Candidate* means folder names were seen but behaviour is unconfirmed.

| Azure resource | Closest existing type | Gap? |
|---|---|---|
| PostgreSQL | `Radius.Data/postgreSqlDatabases` (contrib); `Radius.Resources/postgreSqlDatabases` (Adaptive Apps) | Two overlapping definitions |
| SQL | `Radius.Data/sqlServerDatabases` (contrib) | No |
| Blob Storage | `Radius.Storage/objectStorage` (contrib) | No |
| Azure Files | `Radius.Compute/persistentVolumes` (contrib, *candidate*) | To confirm |
| Service Bus | `Radius.Messaging/rabbitMQ`, `kafka` (contrib, broker-specific); `Radius.Resources/mqttBrokers` (Adaptive Apps, MQTT) | **Yes.** Our `BusinessContinuity.Messaging/messageQueues` is custom |
| Key Vault | `Radius.Security/secrets` (contrib, *candidate*) | To confirm |
| Log Analytics | None as a type; Adaptive Apps delivers OpenTelemetry/Prometheus through its `core` capability portfolio | Platform concern |
| Virtual Network | None (`Radius.Compute/routes` covers ingress only) | Guide only |

## 3. Concepts from Adaptive Apps worth considering later

- **Capability portfolios** (`min`, `core`, `ent`, plus `-ai`) are Helm-delivered sets of platform capabilities: OIDC, workload identity, service mesh, observability, policy, on-cluster AI. The library's `targets/` pages could reference a portfolio instead of re-describing platform prerequisites.
- **Programming model:** Dapr is preferred but optional; apps may bind to platform APIs directly when parity exists across targets. This is consistent with the library's portability classes.
- **Assets that already exist there:** the `ada` CLI, the Simplified Trading App and a MicroHack. The library should link to them rather than copy.

## 4. Points to reconcile

- Adaptive Apps' portfolio table lists **Entra Managed Identity** for workload identity on Azure Local and other targets. Our ALDO work found only system-assigned identity, so no federated credential for workloads; we substitute Keycloak and AD DS.
- Its comparison has no **disconnected** column.
- Its on-cluster AI path is KAITO. Foundry Local on Azure Local is a separate option we researched; it is out of scope for the eight resources but a candidate follow-up guide.

## 5. Limits of this check

- Several `docs.radapp.io` URLs returned 404; findings rely on the concepts page and the `resource-types-contrib` repository and docs.
- Statements about what Adaptive Apps does not contain are based on its directory listing and README, not a full code review.
