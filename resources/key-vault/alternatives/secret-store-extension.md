# Key Vault with the Secret Store extension on Azure Local

The [Azure Key Vault Secret Store extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension) (generally available) is an Arc extension for Arc-enabled Kubernetes clusters, such as AKS on Azure Local with connected operations. On a schedule, it copies secrets from Key Vault in Azure into Kubernetes Secrets in the cluster. Apps read those Kubernetes Secrets, so they keep working when the site loses its connection to Azure. Only new or changed secrets wait until the connection is back.

```text
Key Vault (Azure)
      │  workload identity federation: the extension's service account → managed identity
      ▼
Secret Store extension (in the cluster)
      │  SecretProviderClass: which vault and which secrets
      │  SecretSync: which Kubernetes Secret to write
      ▼
Kubernetes Secret  ──►  application pod (environment variable or mounted file)
```

## Key Vault on AKS compared with the extension on Azure Local

| | AKS with the Key Vault Secrets Provider | AKS on Azure Local with the Secret Store extension |
|---|---|---|
| Who calls Key Vault | The CSI driver, as the application's workload identity | The extension, as its own workload identity |
| Where the secret lives in the cluster | Mounted into the pod; optionally synced to a Kubernetes Secret | Always a Kubernetes Secret |
| When Key Vault is unreachable | A new pod can't mount the secret | Pods keep reading the copied Secret |
| Rotation | Polled by the driver | Polled by the extension (`rotationPollIntervalInSeconds`) |
| Secrets | ✅ | ✅ |
| Certificates | ✅ | ✅ With the private key, as a `kubernetes.io/tls` Secret; the key must be exportable |
| Key operations (sign, encrypt, wrap) | Call Key Vault | Call Key Vault, so they need the link to Azure |
| Direction | Key Vault → cluster | Key Vault → cluster. Secrets created on site aren't copied back. |

The older Azure Key Vault Secrets Provider extension for Arc retires on 9 October 2027. Don't install it next to the Secret Store extension.

## How the Order Management sample does it

The order processor signs every order it archives with HMAC-SHA256 ([ArchiveSigner.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Storage/ArchiveSigner.cs)), so a reader can tell an archived order wasn't altered. The key is Key Vault secret `archive-signing-key`. The processor reads it from the file `/var/run/secrets/archive-signing/key` on both platforms; only how the file gets there differs. Other services' credentials don't go through the vault: on Azure they use workload identity with managed identities, and on Azure Local they're generated on site.

| Step | On Azure | On Azure Local |
|---|---|---|
| Vault and roles | [platform-resources.bicep](../../../samples/OrderManagementApp/infra/azure/platform-resources.bicep): Key Vault with RBAC; Key Vault Secrets User for the processor's identity only, Secrets Officer for the cluster administrators | [key-vault.bicep](../../../samples/OrderManagementApp/infra/azurelocal/key-vault.bicep), deployed by [key-vault.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/key-vault.ps1): Key Vault with RBAC and purge protection, a managed identity with Key Vault Secrets User federated with the `secret-sync` service account, Secrets Officer for whoever runs the script |
| Reader in the cluster | The AKS Key Vault Secrets Provider add-on (CSI driver, two-minute rotation poll) | The Secret Store extension (hourly poll); the cluster gets workload identity and the Certificate Management extension, which it requires, when it's created ([platform-resources.bicep](../../../samples/OrderManagementApp/infra/azurelocal/platform-resources.bicep)) |
| Signing key | Created once with a random value by [provision-infra.ps1](../../../samples/OrderManagementApp/scripts/infra/azure/provision-infra.ps1) | Created once with a random value by key-vault.ps1 |
| What reads the vault | SecretProviderClass `archive-signing`, applied by provision-infra.ps1, as the processor's own identity | [key-vault-sync.yaml](../../../samples/OrderManagementApp/infra/azurelocal/key-vault-sync.yaml): SecretProviderClass and SecretSync `archive-signing`, as the `secret-sync` service account, written to Kubernetes Secret `archive-signing` |
| Into the processor | The [Recipe Pack](../../../recipe-packs/azure.bicep) (`keyVaultFiles`) adds a CSI volume to the processor's pods only | The [Recipe Pack](../../../recipe-packs/azure-local.bicep) (`keyVaultFiles`) mounts Secret `archive-signing` into the processor's pods only |
| Without the link to Azure | Not applicable | The processor keeps signing with the synced Secret; a new key version arrives once the link is back |

Rotate the key by setting a new version of `archive-signing-key` in the vault. The processor rereads the file every minute, so it signs with the new key once the driver or extension has brought it. Each archived order records the ID of the key that signed it (`signingkeyid` in the blob's metadata), so keep old versions for as long as you verify old orders.

Database passwords and object store keys on Azure Local are generated in the cluster by the setup and deploy scripts, and changed with [rotate-credentials.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/rotate-credentials.ps1), which needs no link to Azure. Workload identity gives the cluster's tokens a public issuer URL, so [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json) sets Keycloak's `issuerDiscoveryUrl` to `https://kubernetes.default.svc`, and Keycloak reads the signing keys from the API server, not from Azure. Check that the `jwks_uri` in `kubectl get --raw /.well-known/openid-configuration` is on site.

## Not covered by the sample

The sample's setup is for demonstration. Depending on your workload's requirements, a production deployment might also need:

- confirm how Secrets are encrypted at rest in your cluster;
- alert when a secret stops syncing;
- decide how long the site may run with a secret that can't be rotated, within Arc's 90-day limit;
- decide how public TLS certificates renew. Certificates copied from Key Vault renew only while the site is connected; certificates issued on each site (for example ACME with DNS validation) renew without Azure.

## References

- [Use the Secret Store extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension)
- [Secret Store extension reference](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension-reference)
- [Workload identity on AKS on Azure Local](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/workload-identity)
- [Workload identity federation in Arc-enabled Kubernetes](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-workload-identity)
- [Arc-enabled Kubernetes connectivity modes](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-connectivity-modes)
- [Key Vault Secrets Provider on AKS](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
