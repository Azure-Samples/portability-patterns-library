# Azure Storage account → Azure Local

Azure Storage isn't available on Azure Local. This guide covers two of its services: Blob storage and Azure Files. For each, it shows what you can use instead, what stays the same, and what you change in your workload.

## Blob storage

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [SeaweedFS](./alternatives/seaweedfs.md) | `adapter-required` | Sample available | Open-source object store (Apache-2.0) you run in the cluster, with an S3 API. The application needs an S3 client behind its storage interface. |
| Azure Local | [Ceph Object Gateway through Rook](https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-storage/) | — | Documentation available | Not evaluated by this project. S3-compatible object storage in a Ceph cluster, which can also serve file shares and block storage. Heavier to run. |
| Azure Local | [Azure Container Storage enabled by Azure Arc](https://learn.microsoft.com/azure/azure-arc/container-storage/overview) | — | Documentation available | Not evaluated by this project. In preview. Files on a shared volume, uploaded to or mirrored from Blob storage; applications use file I/O, not the Blob SDK. Designed for outages of up to 72 hours. |

[Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite), Microsoft's Blob storage emulator, keeps the Blob API but isn't supported for production. Use it for local development only.

### What carries over

- **The data model:** containers become buckets, blobs become objects, with the same names, prefixes, content types and user metadata.
- **The payloads and the application logic** behind your own storage interface.
- **Common features under other names:** versioning, immutability (S3 Object Lock), lifecycle rules, tags, and shared access signatures as presigned URLs.
- **Access without a stored key**, if the store accepts tokens. SeaweedFS can exchange a token for temporary keys. The sample uses ordinary S3 keys instead.

### What you need to change

1. **Put storage behind your own interface.** Move the Blob SDK calls into one class that implements it.
2. **Add an S3 version of that class.** Use an S3 client, such as the [AWS SDK for .NET](https://aws.amazon.com/sdk-for-net/), pointed at the on-site endpoint.
3. **Pick the class at startup** from configuration. Use the same image on both targets.
4. **Change how the app signs in.** Entra ID role assignments become S3 access keys, or temporary keys exchanged for a token.
5. **Replace Blob-only features you use.** [Access tiers](https://learn.microsoft.com/azure/storage/blobs/access-tiers-overview), append and page blobs, change feed and Event Grid events have no direct equivalent.
6. **Run the store yourself.** You handle capacity, replication, TLS, backups and upgrades.

How Blob storage maps to SeaweedFS, and what to watch on Azure Local: [SeaweedFS as an alternative](./alternatives/seaweedfs.md).

### Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Not the Blob API, so the Blob SDK doesn't work against it. Objects and buckets carry over; access tiers, append and page blobs, change feed and Event Grid events don't. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | No Entra ID role assignments. Use S3 access keys, or temporary keys exchanged for a token. The sample gives each namespace its own keys, limited to its own buckets. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | You host, size, back up and scale the store. There's no [geo-redundant storage](https://learn.microsoft.com/azure/storage/common/storage-redundancy); copying to a second site is yours to set up. Azure Local's Storage Spaces Direct already keeps copies of the cluster's disks, so size the store's own replication with that in mind. |

**Data:** blobs don't move by themselves. Copy them with a tool that speaks both APIs, such as [rclone](https://rclone.org/).

## Azure Files

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Windows Server file server](https://learn.microsoft.com/windows-server/storage/file-server/file-server-smb-overview) | — | Documentation available | Not evaluated by this project. SMB 3 and NFS shares from a Windows Server VM on the Azure Local instance, joined to Active Directory. Same protocols and NTFS permissions; the share path changes. |

Other options for specific uses: Samba (GPL-3.0) for SMB shares from Linux; CephFS through Rook, if Ceph already stores your objects; the SeaweedFS CSI driver or Azure Container Storage enabled by Azure Arc for volumes shared between pods only. This project hasn't evaluated them.

### What carries over

- **The protocols:** SMB 3 and NFS, so applications and users that mount a share keep working.
- **Identities and permissions**, if you use [Active Directory authentication](https://learn.microsoft.com/azure/storage/files/storage-files-active-directory-overview) with Azure Files: the same accounts, groups and NTFS permissions.
- **The folder structure and files.**
- **Shared volumes for pods:** `ReadWriteMany` volumes through a CSI driver, as with Azure Files on AKS.

### What you need to change

1. **Set up a file server.** Create a Windows Server [VM on the Azure Local instance](https://learn.microsoft.com/azure/azure-local/manage/create-arc-virtual-machines), join it to Active Directory, and create SMB or [NFS](https://learn.microsoft.com/windows-server/storage/nfs/nfs-overview) shares.
2. **Change the share paths.** `\\<account>.file.core.windows.net\<share>` becomes `\\<server>\<share>`.
3. **Sign in with Active Directory accounts.** Storage account keys and Microsoft Entra Kerberos aren't available.
4. **For pods, change the CSI driver.** Replace the [Azure Files CSI driver](https://learn.microsoft.com/azure/aks/azure-files-csi) with the [SMB or NFS CSI driver on AKS on Azure Local](https://learn.microsoft.com/azure/aks/aksarc/container-storage-interface-files). Create the shares in advance, and keep the SMB credentials in a Kubernetes Secret.
5. **If the app uses the [Azure Files REST API](https://learn.microsoft.com/rest/api/storageservices/file-service-rest-api) or SDK, mount the share instead.** No on-site store offers that API.
6. **Replace data protection.** Use [Volume Shadow Copies](https://learn.microsoft.com/windows-server/storage/file-server/volume-shadow-copy-service) and your own backups instead of [share snapshots](https://learn.microsoft.com/azure/storage/files/storage-snapshots-files), soft delete and Azure Backup.

### Observed limitations

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Same protocols, but no Azure Files REST API, and no share-level quotas or snapshots managed through Azure. |
| [Identity and access management](https://learn.microsoft.com/azure/well-architected/security/identity-access) | Microsoft Entra Kerberos and Azure role assignments on shares aren't available. Users need Active Directory accounts. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | A single VM is a single point of failure. For high availability, run the file server on a [failover cluster](https://learn.microsoft.com/windows-server/failover-clustering/failover-clustering-overview), and back it up yourself. |

**Data:** files don't move by themselves. Copy them with [Robocopy](https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy), or keep a Windows Server in step with the Azure file share through [Azure File Sync](https://learn.microsoft.com/azure/storage/file-sync/file-sync-introduction) while the link is up. Turn cloud tiering off if the files must be readable without Azure.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) archives each order as a JSON object: in Blob storage on Azure and in SeaweedFS on Azure Local, where SeaweedFS also holds the PostgreSQL backups. [SeaweedFS as an alternative](./alternatives/seaweedfs.md#how-the-order-management-sample-does-it) points to the code. The sample doesn't use Azure Files.
