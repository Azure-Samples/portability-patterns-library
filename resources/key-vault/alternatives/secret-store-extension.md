# Key Vault with the Secret Store extension on Azure Local

The [Azure Key Vault Secret Store extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension) (generally available) is an Arc extension for Kubernetes clusters, including AKS on Azure Local. It copies secrets from Key Vault into Kubernetes Secrets on a schedule, so workloads read them locally and keep working while the cluster is disconnected.

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

On Azure every service signs in with workload identity, so there are no secrets. On Azure Local, the sample sets up the vault and the extension for secrets that already live in Azure; its own credentials are generated on site:

| Step | In the sample |
|---|---|
| Workload identity on the cluster | [platform-resources.bicep](../../../samples/OrderManagementApp/infra/azurelocal/platform-resources.bicep) turns on the OIDC issuer and workload identity when the cluster is created, and installs the Certificate Management extension, the cluster's one cert-manager, which the Secret Store extension requires |
| Vault, identity and extension | [key-vault.bicep](../../../samples/OrderManagementApp/infra/azurelocal/key-vault.bicep), deployed by [key-vault.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/key-vault.ps1): Key Vault with RBAC and purge protection, a managed identity with Key Vault Secrets User federated with the `secret-sync` service account, and the extension (hourly poll) |
| Syncing a secret from Azure | [key-vault-sync.yaml](../../../samples/OrderManagementApp/infra/azurelocal/key-vault-sync.yaml) creates the `secret-sync` service account and shows the `SecretProviderClass` and `SecretSync` for a partner API key. Nothing is synced by default. |
| Credentials born on site | Database passwords and object store keys are generated in the cluster by the setup and deploy scripts, and changed with [rotate-credentials.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/rotate-credentials.ps1), which needs no link to Azure |
| Keycloak and the new issuer | Workload identity gives the cluster's tokens a public issuer URL. [realm.json](../../../samples/OrderManagementApp/infra/azurelocal/keycloak/realm.json) sets Keycloak's `issuerDiscoveryUrl` to `https://kubernetes.default.svc`, so Keycloak reads the signing keys from the API server, not from Azure. Check that the `jwks_uri` in `kubectl get --raw /.well-known/openid-configuration` is on site. |

## Not covered by the sample

The sample is sample code. Before production:

- confirm how Secrets are encrypted at rest in your cluster;
- alert when a secret stops syncing;
- decide how long the site may run with a secret that can't be rotated, within Arc's 90-day limit;
- for public TLS certificates, prefer issuing them on each site (for example ACME with DNS validation) over copying them from Key Vault, so renewal doesn't depend on Azure.

## References

- [Use the Secret Store extension](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension)
- [Secret Store extension reference](https://learn.microsoft.com/azure/azure-arc/kubernetes/secret-store-extension-reference)
- [Workload identity on AKS on Azure Local](https://learn.microsoft.com/azure/aks-hybrid-edge/local/hyperconverged/workload-identity)
- [Workload identity federation in Arc-enabled Kubernetes](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-workload-identity)
- [Arc-enabled Kubernetes connectivity modes](https://learn.microsoft.com/azure/azure-arc/kubernetes/conceptual-connectivity-modes)
- [Key Vault Secrets Provider on AKS](https://learn.microsoft.com/azure/aks/csi-secrets-store-driver)
- [Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
