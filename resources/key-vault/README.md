# Azure Key Vault → Azure Local

Azure Key Vault runs in Azure. A workload on Azure Local that has to keep working while the site is cut off from Azure needs its secrets available on site. This guide describes the alternatives this project explored, what stays the same, and what you change in your workload.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Key Vault with the Secret Store extension](./alternatives/secret-store-extension.md) | `adapter-required` | Sample available | Secrets stay in Key Vault in Azure. An Arc extension copies them into Kubernetes Secrets in the cluster, which keep working offline. For secrets that already live in Azure. |
| Azure Local | [OpenBao](https://openbao.org/docs/) | — | Documentation available | Not evaluated by this project. Open-source vault (MPL-2.0, a fork of HashiCorp Vault) run on site, with Kubernetes sign-in and short-lived database credentials. |
| Azure Local | [Key Vault with disconnected operations](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-overview) | — | Documentation available | Not evaluated by this project. The Key Vault service runs on site, for Azure Local instances approved for disconnected operations. |

## What carries over

- **Key Vault as the source of truth:** secrets are created, rotated and audited in Key Vault, with the same names and the same Azure RBAC.
- **Identity, with a different issuer:** the extension signs in to Key Vault with workload identity federation, like a workload on AKS.
- **The application's code**, if it already reads secrets from mounted files or environment variables, for example through the [Key Vault Secrets Provider](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver) on AKS.

## What you need to change

1. **Read secrets from files or environment variables.** On Azure Local the app reads a Kubernetes Secret and never calls Key Vault. Do the same on AKS to keep one code path.
2. **List the secrets to copy.** Create a `SecretProviderClass` and a `SecretSync` for each Kubernetes Secret, in the app's namespace.
3. **Give Key Vault access to the extension, not the app.** Create a managed identity with the Key Vault Secrets User role, and federate it with the extension's service account.
4. **Pick up changed secrets.** A new value reaches the cluster on the extension's next check. Restart the service, or have it reread the file. A database password must also be changed in the database.
5. **Plan for keys.** Signing, encryption and key wrapping with Key Vault keys need Key Vault itself, so they don't work offline.

How the extension maps to Key Vault on AKS, and how the sample uses it: [Key Vault with the Secret Store extension](./alternatives/secret-store-extension.md).

## Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Application secrets](https://learn.microsoft.com/azure/well-architected/security/application-secrets) | Secrets are copied into the cluster, so Kubernetes RBAC on the namespace becomes the boundary that protects them. Access isn't audited by Key Vault after the copy. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | The extension needs workload identity on the cluster. On AKS on Azure Local this is in preview, and you can only turn it on when you create the cluster. It also moves the cluster's token issuer to an Azure address. On-site services that check those tokens, such as Keycloak, must then fetch the signing keys from the cluster's API server to keep working offline. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | Secrets already copied keep working offline. New and rotated secrets wait until the link to Azure returns. Arc-enabled Kubernetes expects the link back [within 90 days](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-connectivity-modes), and doesn't support fully disconnected sites. |

**Data:** secrets stay in Key Vault. Nothing moves; the cluster holds copies.

**What it covers on Azure Local:** secrets and certificates that already live in Azure and must reach the site, such as a partner's API key. Key Vault keeps a copy outside the cluster and gives central rotation and audit, but rotation only works while the site is connected. In the sample, secrets that only matter on site, such as database passwords, are Kubernetes Secrets generated on site. A rebuilt cluster gets new ones.

## Rotating secrets on site

Key Vault doesn't rotate database passwords itself on Azure either: you write a function, triggered by a near-expiry event, that changes the password in the database and stores the new version. On Azure Local the same pattern runs on site:

| Option | What it does | Notes |
|---|---|---|
| A rotation script or workflow on site | Changes the value in the database or store, updates the Kubernetes Secret, restarts or reloads the clients | No extra platform. What the sample does. |
| [OpenBao](https://openbao.org/docs/) | Rotates PostgreSQL, MySQL and Active Directory passwords on a schedule, issues short-lived database users and certificates | Open source (MPL-2.0). No SQL Server plugin. You run it, including unsealing after a restart. |
| [HashiCorp Vault](https://developer.hashicorp.com/vault/docs/secrets/databases) | The same, and SQL Server | Business Source License, not open source. Enterprise adds replication between sites. |

Secrets without a plugin, such as S3 keys or partner API keys, need their own rotation in every option.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) on Azure Local sets up Key Vault and the Secret Store extension for secrets that already live in Azure, and shows how to sync one. Nothing is synced by default. The sample's own passwords and keys are generated on site and changed with a rotation script. On Azure the sample needs no secrets, because every service signs in with workload identity. [Key Vault with the Secret Store extension](./alternatives/secret-store-extension.md#how-the-order-management-sample-does-it) points to the code.
