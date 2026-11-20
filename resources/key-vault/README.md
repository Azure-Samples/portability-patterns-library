# Azure Key Vault → Azure Local

Azure Key Vault runs in Azure, but workloads on Azure Local need their secrets available on site. This guide covers how workloads on Azure Local with [connected operations](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/azure-local/connected-operations-overview) get their secrets on site. It describes the alternatives this project explored, what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code.

Azure Local with [disconnected operations](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-overview) runs Key Vault itself on site. This guide doesn't cover that case yet.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Key Vault with the Secret Store extension](./alternatives/secret-store-extension.md) | `adapter-required` | Sample available | An Arc extension that syncs secrets from Key Vault in Azure to an Arc-enabled Kubernetes cluster on Azure Local with connected operations. Apps read the copies, stored as Kubernetes Secrets, even when the site loses its connection to Azure; syncing resumes when it's back. Useful for secrets you already keep in Key Vault, such as a third-party API key. |
| Azure Local | [OpenBao](https://openbao.org/docs/) | — | Documentation available | Not evaluated by this project. Open-source vault (MPL-2.0, a fork of HashiCorp Vault) run on site, with Kubernetes sign-in and short-lived database credentials. |
| Azure Local | [HashiCorp Vault](https://developer.hashicorp.com/vault/docs) | — | Documentation available | Not evaluated by this project. Vault Community Edition is free to run in production within your organization, under the Business Source License (source-available, not open source). It runs on site, with Kubernetes sign-in and short-lived database credentials, including SQL Server. |
| Azure Local | [Key Vault with disconnected operations](https://learn.microsoft.com/azure/azure-local/manage/disconnected-operations-overview) | — | Documentation available | Not evaluated by this project. The Key Vault service runs on site, for Azure Local instances approved for disconnected operations. |

## What stayed the same in the sample

- **Key Vault as the source of truth** for secrets that live in Azure: they're created, rotated and audited in Key Vault, with the same names and the same Azure RBAC.
- **Identity, with a different issuer:** the extension signs in to Key Vault with workload identity federation, like a workload on AKS.
- **The application's code:** the sample's order processor signs archived orders with a key from Key Vault, which it reads from a mounted file, `/var/run/secrets/archive-signing/key`, on both platforms. It never calls Key Vault, so its code is the same on AKS, where the [Key Vault Secrets Provider](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver) mounts the file, and on Azure Local, where it comes from the synced Secret.

## What the sample needed to change

1. **The file comes from a Kubernetes Secret.** On AKS the CSI driver mounts the secret straight from Key Vault. On Azure Local the Recipe Pack mounts the Kubernetes Secret the extension writes, at the same path.
2. **Secrets to copy listed per namespace.** A `SecretProviderClass` and a `SecretSync` name the vault's `archive-signing-key` and the Secret it's written to.
3. **Key Vault access given to the extension, not the app.** On AKS the processor's own identity reads the vault. On Azure Local a managed identity with the Key Vault Secrets User role is federated with the extension's service account, and Kubernetes RBAC decides which pods can mount the Secret.
4. **Credentials that only matter on site generated on site.** Database passwords and object store keys are created in the cluster and changed with a rotation script, which needs no link to Azure.

A synced secret's new value reaches the cluster on the extension's next check, so the app has to reread it: the processor rereads the key file every minute. Signing, encryption and key wrapping with Key Vault *keys* need Key Vault itself, so they don't work offline; that's why the sample signs with a *secret* it holds, not a Key Vault key.

How the extension maps to Key Vault on AKS, and the sample's code for each step: [Key Vault with the Secret Store extension](./alternatives/secret-store-extension.md).

## Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Application secrets](https://learn.microsoft.com/azure/well-architected/security/application-secrets) | Secrets are copied into the cluster, so Kubernetes RBAC on the namespace becomes the boundary that protects them. Access isn't audited by Key Vault after the copy. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | The extension needs workload identity on the cluster. On AKS on Azure Local this is in preview, and it can only be turned on when the cluster is created. It also moves the cluster's token issuer to an Azure address. On-site services that check those tokens, such as Keycloak, must then fetch the signing keys from the cluster's API server to keep working offline. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | Secrets already copied keep working offline. New and rotated secrets wait until the link to Azure returns. Azure Local with connected operations supports [disconnections of up to 30 days](https://learn.microsoft.com/azure/azure-sovereign-clouds/private/azure-local/connected-operations-overview) without affecting running workloads. The Arc-enabled cluster's identity certificate is [valid for up to 90 days](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-connectivity-modes) without a connection. Fully disconnected sites need disconnected operations instead. |

**Data:** secrets stay in Key Vault. Nothing moves; the cluster holds copies.

**What it covers on Azure Local:** secrets and certificates that live in Azure and must reach the site, such as the sample's archive signing key or a partner's API key. Key Vault keeps a copy outside the cluster and gives central rotation and audit, but rotation only works while the site is connected. In the sample, secrets that only matter on site, such as database passwords, are Kubernetes Secrets generated on site. A rebuilt cluster gets new ones.

## Rotating secrets on site

Key Vault doesn't rotate database passwords itself on Azure either: a function, triggered by a near-expiry event, changes the password in the database and stores the new version. On Azure Local the same pattern runs on site. The options this project looked at:

| Option | What it does | Notes |
|---|---|---|
| A rotation script or workflow on site | Changes the value in the database or store, updates the Kubernetes Secret, restarts or reloads the clients | No extra platform. What the sample does. |
| [OpenBao](https://openbao.org/docs/) | Rotates PostgreSQL, MySQL and Active Directory passwords on a schedule, issues short-lived database users and certificates | Open source (MPL-2.0). No SQL Server plugin. Runs on site, including unsealing after a restart. |
| [HashiCorp Vault](https://developer.hashicorp.com/vault/docs/secrets/databases) | The same, and SQL Server | Free Community Edition under the Business Source License (source-available, not open source). Enterprise adds replication between sites. |

Secrets without a plugin, such as S3 keys or partner API keys, need their own rotation in every option.

**Certificates:** the sample issues its TLS certificates on site, from the site's certificate authority through cert-manager, so they renew without Azure. Syncing certificates from Key Vault wasn't tested.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) keeps the key its order processor signs archived orders with in Key Vault, on Azure and on Azure Local. On Azure Local the Secret Store extension syncs it to the site, so archiving keeps working without the link to Azure. The sample's other passwords and keys on Azure Local are generated on site and changed with a rotation script; on Azure every service signs in with workload identity instead. [Key Vault with the Secret Store extension](./alternatives/secret-store-extension.md#how-the-order-management-sample-does-it) links the code for each change above.
