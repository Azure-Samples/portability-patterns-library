# SeaweedFS as an alternative to Azure Blob storage

> **Draft.** Links to the sample's code follow once the SeaweedFS implementation is in the Order Management sample.

[SeaweedFS](https://github.com/seaweedfs/seaweedfs) is an open-source distributed store (Apache-2.0) that serves objects over an [S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API). On Azure Local it runs in the cluster, from the [Helm chart](https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs), and keeps the objects that Blob storage keeps on Azure. It's built for many small files: each object is one disk read, with about 40 bytes of metadata.

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

- **Replication and Storage Spaces Direct.** The cluster's node disks already sit on Storage Spaces Direct, which keeps copies of every write. SeaweedFS's own replication protects against losing a node or volume server; choose its replication factor knowing the disks underneath are already redundant.
- **Images.** Mirror the SeaweedFS images into the in-cluster registry, like every other image on Azure Local, so a restarted pod still finds its image without the link to Azure.
- **Credentials.** Temporary credentials from service account tokens keep the application free of stored keys. Static access keys belong in a Kubernetes Secret, ideally synced from a vault (see the [Key Vault guide](../../key-vault/README.md)).
- **TLS.** Serve the S3 endpoint with a certificate from the site CA, and have the application trust it.

## How the Order Management sample does it

The processor archives each order as a JSON object:

| Step | In the sample |
|---|---|
| Same deployment definition on both targets | The app declares a `Radius.Storage/objectStorage` resource. On Azure its Recipe creates a storage account; on Azure Local, SeaweedFS. |
| Interface the application codes against | `IArchiveStore`, with a Blob implementation and an S3 implementation |
| Choosing the implementation at startup | From the values the storage Recipe returns |
| Idempotent writes | Each order's object is named after the order, so a redelivered order overwrites the same object |

## Not covered by the sample

The sample's SeaweedFS is sample code. Before production, add:

- three masters and enough volume servers for your replication;
- backups, or replication to a second site;
- TLS on every endpoint and credentials scoped per bucket;
- monitoring of capacity and volume health.

## References

- [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
- [SeaweedFS S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [SeaweedFS Helm chart](https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs)
- [Introduction to Azure Blob storage](https://learn.microsoft.com/azure/storage/blobs/storage-blobs-introduction)
- [Azure Well-Architected: Azure Blob Storage](https://learn.microsoft.com/azure/well-architected/service-guides/azure-blob-storage)
- [rclone](https://rclone.org/), for copying between Blob storage and S3
