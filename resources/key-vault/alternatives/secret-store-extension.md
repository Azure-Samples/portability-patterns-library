# Key Vault with the Secret Store extension on Azure Local

> **Draft.** The Order Management sample doesn't use it yet. The sample is planned.

The [Azure Key Vault Secret Store extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension) (generally available) is an Arc extension for Kubernetes clusters, including AKS on Azure Local. It copies secrets from Key Vault into Kubernetes Secrets, on a schedule, so workloads read them locally and keep working while the cluster is disconnected.

```text
Key Vault (Azure)
      │  workload identity federation: the extension's service account → managed identity
      ▼
Secret Store extension (in the cluster)
      │  SecretProviderClass: which vault and which secrets
      │  SecretSync: which Kubernetes Secret to write
      ▼
Kubernetes Secret  ──►  application pod (mounted file or environment variable)
```

## Key Vault on AKS compared with the extension on Azure Local

| | AKS with the Key Vault Secrets Provider | AKS on Azure Local with the Secret Store extension |
|---|---|---|
| Who calls Key Vault | The CSI driver, as the application's workload identity | The extension, as its own workload identity |
| Where the secret lives in the cluster | Mounted into the pod; optionally synced to a Kubernetes Secret | Always a Kubernetes Secret, stored in etcd |
| When Key Vault is unreachable | A new pod can't mount the secret | Pods keep reading the copied Secret |
| Rotation | Polled by the driver | Polled by the extension (`rotationPollIntervalInSeconds`) |
| Application reads | Files or environment variables | Files or environment variables |
| Keys and certificates | Certificates can be retrieved as secrets; key operations call Key Vault | Same; key operations need the link to Azure |

The older Azure Key Vault Secrets Provider extension for Arc retires on 9 October 2027. Don't install it next to the Secret Store extension.

## Setting it up on AKS on Azure Local

1. **Workload identity federation on the cluster.** On AKS on Azure Local it's [enabled when the cluster is created](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/workload-identity) (`--enable-oidc-issuer --enable-workload-identity`, preview). An existing cluster has to be recreated.
2. **A managed identity** with the Key Vault Secrets User role on the vault, and a federated credential for the extension's service account. See [workload identity federation in Arc-enabled Kubernetes](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-workload-identity).
3. **The extension** installed on the cluster, with a rotation interval that fits how quickly a changed secret must arrive.
4. **A `SecretProviderClass` and `SecretSync`** for each Kubernetes Secret, in the application's namespace. See the [configuration reference](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension-reference).
5. **Restrict access to the Secret** with Kubernetes RBAC: only the application's service account and the extension should read it.

## How the Order Management sample will do it

Planned:

| Step | Plan |
|---|---|
| What is stored | The application's own SQL Server login, replacing `sa`. |
| How the application reads it | The SQL Recipe on Azure Local reads the copied Kubernetes Secret, so the application's configuration doesn't change. |
| Azure | No Key Vault needed: every service signs in with workload identity. |

## Risks to test

- **The cluster's token issuer.** Enabling workload identity federation sets the issuer that Keycloak trusts for the application's tokens. That trust has to be checked after the cluster is recreated.
- **cert-manager.** The extension requires the [Certificate Management for Azure Arc](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension) extension, which installs cert-manager and trust-manager. The connected registry extension already brings cert-manager to the cluster, so check that the two can coexist.

## Not covered by the sample

Before production:

- encrypt Secrets at rest in etcd and confirm how your cluster does it;
- monitor the extension's sync status and alert when a secret stops updating;
- decide how long the site may run with a secret that can't be rotated.

## References

- [Use the Secret Store extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension)
- [Secret Store extension reference](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension-reference)
- [Workload identity on AKS on Azure Local](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/workload-identity)
- [Key Vault Secrets Provider on AKS](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [Key Vault best practices](https://learn.microsoft.com/azure/key-vault/general/best-practices)
