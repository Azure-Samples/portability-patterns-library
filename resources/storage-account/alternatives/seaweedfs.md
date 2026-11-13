# SeaweedFS as an alternative to Azure Blob storage

[SeaweedFS](https://github.com/seaweedfs/seaweedfs) is an open-source distributed store (Apache-2.0) that serves objects over an [S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API). On Azure Local it runs in the cluster, from the [Helm chart](https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs), and keeps the objects that Blob storage keeps on Azure. Its documentation describes it as built for many small files: each object is one disk read, with about 40 bytes of metadata.

| Part | Role |
|---|---|
| Master | Tracks volumes and where they live. Three for failover. |
| Volume servers | Store the data, on persistent volumes |
| Filer | Directories and object names, with metadata in a store you choose, such as PostgreSQL |
| S3 gateway | The S3 endpoint the application calls. Stateless; scale it out. |

## Blob storage features in SeaweedFS

| Blob storage | SeaweedFS | Notes |
|---|---|---|
| Storage account | SeaweedFS cluster | You deploy and operate it. |
| Container | Bucket | |
| Block blob | Object | |
| Append blob, page blob | No equivalent | |
| Metadata, index tags | User metadata, object tags | |
| Access tiers, lifecycle management | Lifecycle rules; tiered storage across disk types | No archive tier. |
| Versioning, soft delete | Versioning | |
| [Immutable storage](https://learn.microsoft.com/azure/storage/blobs/storage-blob-immutable-storage) | Object Lock with retention and legal hold | |
| [Shared access signatures](https://learn.microsoft.com/azure/storage/common/storage-sas-overview) | Presigned URLs | |
| Microsoft Entra ID role assignments | IAM users and policies, bucket policies | |
| Workload identity, no stored key | STS with OpenID Connect or Kubernetes service account tokens | Temporary credentials instead of an access key. |
| Account keys | S3 access keys | |
| Encryption with customer-managed keys | Server-side encryption with a key provider, including Azure Key Vault and OpenBao | |
| LRS, ZRS | Replication placement, and erasure coding for less-used data | |
| GRS, object replication | Replication between SeaweedFS clusters, active-active or active-passive | Set up per site pair. |
| Private endpoint | Kubernetes Service and network policies | |
| Azure Monitor metrics | Prometheus metrics | |
| Blob SDK | Any S3 client, such as the AWS SDK for .NET | The application code changes. |

## On Azure Local

- **Replication and Storage Spaces Direct.** SeaweedFS stores its data on the cluster's persistent volumes. On Azure Local these sit on Storage Spaces Direct, which already keeps copies of every write. SeaweedFS's own replication protects against losing a node or a volume server. The sample keeps two copies. One copy also works and relies on the disks underneath, but objects on a lost volume server can't be read until its pod runs again.
- **One store per cluster.** Run it once, as a platform service, and give each application its own buckets and keys, rather than one store per application.
- **Images.** Mirror the SeaweedFS images into the in-cluster registry, like every other image on Azure Local, so a restarted pod still finds its image without the link to Azure.
- **Credentials.** Keep S3 keys in a Kubernetes Secret, and give it only to the pods that need it. The store and its clients are both on site, so the keys don't need a copy outside the cluster. A rebuilt store gets new keys. To avoid storing a key in the app, SeaweedFS can exchange a token for temporary keys. The token can come from the site's identity provider, such as Keycloak, or be a Kubernetes service account token. The second option needs extra setup, because SeaweedFS can't sign in to fetch the cluster's signing keys.
- **TLS.** Serve the S3 endpoint with a certificate from the site CA, and have the application trust it.

## How the Order Management sample does it

The processor archives each order as a JSON object:

| Step | In the sample |
|---|---|
| Same deployment definition on both targets | The app declares a [`Radius.Storage/objectStorage`](../../../samples/OrderManagementApp/deploy/app.bicep) resource. On Azure the [Blob Recipe](../../../recipes/object-storage/azure/blob-storage/blob-objectstorage.bicep) creates a storage account; on Azure Local the [SeaweedFS Recipe](../../../recipes/object-storage/azure-local/seaweedfs/seaweedfs-objectstorage.bicep) creates nothing: it names a bucket, `<namespace>.<containerName>`, and returns the store's endpoint. |
| The store | Installed once per cluster by [provision-object-store.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/provision-object-store.ps1) with [these values](../../../samples/OrderManagementApp/infra/azurelocal/object-store/values.yaml): three masters, three volume servers keeping two copies of every object, two filers and two S3 gateways, each on its own node. With availability `standard`, one of each. See the [object store README](../../../samples/OrderManagementApp/infra/azurelocal/object-store/README.md). |
| Encryption | HTTPS with a certificate from the site CA, mutual TLS between the store's components, and every chunk encrypted before it reaches a volume server. Volume servers accept writes only with a token signed by the masters; every component runs unprivileged, and disruption budgets let a node drain take one pod of each component at a time. |
| Access | An S3 identity per namespace, allowed only that namespace's buckets. Its keys are generated on site and kept in the cluster. The Recipe Pack gives them only to containers connected to object storage, and a [network policy](../../../samples/OrderManagementApp/infra/azurelocal/object-store/network-policy.yaml) lets only them in. |
| Changing keys | [rotate-credentials.ps1](../../../samples/OrderManagementApp/scripts/infra/azurelocal/rotate-credentials.ps1) adds a new key next to the old one, restarts the S3 gateways, moves the clients to it, then removes the old key, with no downtime and no link to Azure. PostgreSQL's backup keys reload without a restart. See the [object store README](../../../samples/OrderManagementApp/infra/azurelocal/object-store/README.md). |
| Interface the application codes against | `IArchiveStore`, with [BlobArchiveStore.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Storage/BlobArchiveStore.cs) and [S3ArchiveStore.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Storage/S3ArchiveStore.cs), which uses the AWS SDK for .NET with path-style addressing |
| Choosing the implementation at startup | [ArchiveOptions.cs](../../../samples/OrderManagementApp/src/OrderManagement.Shared/Configuration/ArchiveOptions.cs): S3 when the connection carries access keys, otherwise Blob storage with workload identity |
| Idempotent writes | Both write `yyyy/MM/dd/<order id>.json`, so a redelivered order overwrites the same object |
| Other uses of the store | CloudNativePG backs up PostgreSQL to it, in a bucket per namespace with its own keys |

## Not covered by the sample

The sample's setup is for demonstration. Depending on your workload's requirements, a production deployment might also need:

- a copy of the buckets off the cluster, for example with `weed filer.remote.sync` to Blob storage while the link is up;
- capacity planning: the sample gives each volume server 20 GB;
- scheduled key rotation, if you need it: the sample rotates by script, when you run it;
- optionally, temporary credentials from Keycloak tokens instead of the application's key, as for the queue and the inventory service. The backup keys stay static, because CloudNativePG's backups sign in with keys;
- monitoring of capacity and volume health.

## References

- [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
- [SeaweedFS S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [SeaweedFS Helm chart](https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs)
- [Introduction to Azure Blob storage](https://learn.microsoft.com/azure/storage/blobs/storage-blobs-introduction)
- [Azure Well-Architected: Azure Blob Storage](https://learn.microsoft.com/azure/well-architected/service-guides/azure-blob-storage)
- [rclone](https://rclone.org/), for copying between Blob storage and S3
