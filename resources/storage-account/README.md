# Azure Storage account → Azure Local

Azure Storage isn't available on Azure Local. This guide covers two of its services: Blob storage and Azure Files. For each, it describes the alternatives this project explored. For Blob storage, it also describes what stayed the same and what changed when this project's sample moved from Azure to Azure Local. The [Sample](#sample) section links the code. Azure Files has no sample, so its sections are based on documentation.

> **About the alternatives:** the open-source alternatives in this guide are examples this project explored, not Microsoft recommendations, and other alternatives may exist. Evaluate any alternative against your own requirements.

## Blob storage

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [SeaweedFS](./alternatives/seaweedfs.md) | `adapter-required` | Sample available | Open-source object store (Apache-2.0) you run in the cluster, with an S3 API. The application needs an S3 client behind its storage interface. |
| Azure Local | [Ceph Object Gateway through Rook](https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-storage/) | — | Documentation available | Not evaluated by this project. S3-compatible object storage in a Ceph cluster, which can also serve file shares and block storage. Heavier to run. |
| Azure Local | [Azure Container Storage enabled by Azure Arc](https://learn.microsoft.com/azure/azure-arc/container-storage/overview) | — | Documentation available | Not evaluated by this project. In preview. Files on a shared volume, uploaded to or mirrored from Blob storage; applications use file I/O, not the Blob SDK. Designed for outages of up to 72 hours. |

[Azurite](https://learn.microsoft.com/azure/storage/common/storage-use-azurite), Microsoft's Blob storage emulator, keeps the Blob API but isn't supported for production. Use it for local development only.

### What stayed the same in the sample

- **The data model:** containers became buckets and blobs became objects, with the same names, prefixes, content types and user metadata.
- **The payloads and the application logic** behind the sample's storage interface.
- **Common features under other names:** versioning, immutability (S3 Object Lock), lifecycle rules, tags, and shared access signatures as presigned URLs. The sample uses none of these, so they weren't tested.

### What the sample needed to change

1. **One interface for storage.** The sample moved its Blob SDK calls into one class behind an interface.
2. **An S3 version of that class,** using the [AWS SDK for .NET](https://aws.amazon.com/sdk-for-net/) pointed at the on-site endpoint.
3. **The class chosen at startup** from configuration, so the same image runs on both targets.
4. **Sign-in with S3 keys.** On Azure the sample uses Entra ID role assignments. On Azure Local each namespace has its own S3 access keys, limited to its own buckets. SeaweedFS can also exchange a token for temporary keys, which the sample doesn't use.
5. **SeaweedFS run in the cluster,** with replication and TLS. Capacity, backups and upgrades are left to whoever runs the site.

The sample doesn't use Blob-only features such as [access tiers](https://learn.microsoft.com/azure/storage/blobs/access-tiers-overview), append and page blobs, change feed or Event Grid events. They have no direct equivalent, so an app that uses them would need another approach.

How Blob storage maps to SeaweedFS, and the sample's code for each step: [SeaweedFS as an alternative](./alternatives/seaweedfs.md).

### Limitations observed in the sample

These are the limitations this project found while building the sample. It isn't a complete list.

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Not the Blob API, so the Blob SDK doesn't work against it. Objects and buckets carry over; access tiers, append and page blobs, change feed and Event Grid events don't. |
| [Workload identity](https://learn.microsoft.com/entra/workload-id/workload-identities-overview) | No Entra ID role assignments. The options are S3 access keys, or temporary keys exchanged for a token. The sample gives each namespace its own keys, limited to its own buckets. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | The store is hosted, sized, backed up and scaled on site. There's no [geo-redundant storage](https://learn.microsoft.com/azure/storage/common/storage-redundancy); copying to a second site has to be set up separately. Azure Local's Storage Spaces Direct already keeps copies of the cluster's disks, which affects how much replication the store itself needs. |

**Data:** blobs don't move by themselves. A tool that speaks both APIs, such as [rclone](https://rclone.org/), can copy them.

## Azure Files

| Target | Alternative | Portability class | Availability | Summary |
|---|---|---|---|---|
| Azure Local | [Windows Server file server](https://learn.microsoft.com/windows-server/storage/file-server/file-server-smb-overview) | — | Documentation available | Not evaluated by this project. SMB 3 and NFS shares from a Windows Server VM on the Azure Local instance, joined to Active Directory. Same protocols and NTFS permissions; the share path changes. |

Other options for specific uses: Samba (GPL-3.0) for SMB shares from Linux; CephFS through Rook, if Ceph already stores your objects; the SeaweedFS CSI driver or Azure Container Storage enabled by Azure Arc for volumes shared between pods only. This project hasn't evaluated them.

### What stays the same (from documentation)

This project didn't build a sample for Azure Files. This section and the next two are based on documentation.

- **The protocols:** SMB 3 and NFS, so applications and users that mount a share keep working.
- **Identities and permissions**, with [Active Directory authentication](https://learn.microsoft.com/azure/storage/files/storage-files-active-directory-overview) for Azure Files: the same accounts, groups and NTFS permissions.
- **The folder structure and files.**
- **Shared volumes for pods:** `ReadWriteMany` volumes through a CSI driver, as with Azure Files on AKS.

### What changes (from documentation)

1. **A file server.** For example, a Windows Server [VM on the Azure Local instance](https://learn.microsoft.com/azure/azure-local/manage/create-arc-virtual-machines), joined to Active Directory, with SMB or [NFS](https://learn.microsoft.com/windows-server/storage/nfs/nfs-overview) shares. The rest of this section uses Windows Server as the example.
2. **Share paths.** `\\<account>.file.core.windows.net\<share>` becomes `\\<server>\<share>`.
3. **Sign-in.** With Windows Server, users and apps sign in with Active Directory accounts. Other file servers have their own sign-in options. Storage account keys and Microsoft Entra Kerberos aren't available.
4. **The CSI driver for pods.** The [Azure Files CSI driver](https://learn.microsoft.com/azure/aks/azure-files-csi) is replaced by the [SMB or NFS CSI driver on AKS on Azure Local](https://learn.microsoft.com/azure/aks/aksarc/container-storage-interface-files). Shares are created in advance, and the SMB credentials are kept in a Kubernetes Secret.
5. **Mounting instead of the API.** No on-site store offers the [Azure Files REST API](https://learn.microsoft.com/rest/api/storageservices/file-service-rest-api), so an app that uses it or the SDK has to mount the share instead.
6. **Data protection.** [Volume Shadow Copies](https://learn.microsoft.com/windows-server/storage/file-server/volume-shadow-copy-service) and separate backups take the place of [share snapshots](https://learn.microsoft.com/azure/storage/files/storage-snapshots-files), soft delete and Azure Backup.

### Limitations (from documentation)

| Pattern | Limitation for this resource |
|---|---|
| [Data store](https://learn.microsoft.com/azure/architecture/guide/technology-choices/data-store-overview) | Same protocols, but no Azure Files REST API, and no share-level quotas or snapshots managed through Azure. |
| [Identity and access management](https://learn.microsoft.com/azure/well-architected/security/identity-access) | Microsoft Entra Kerberos and Azure role assignments on shares aren't available. With Windows Server, users need Active Directory accounts. |
| [Reliability](https://learn.microsoft.com/azure/well-architected/reliability/) | A single VM is a single point of failure. A [failover cluster](https://learn.microsoft.com/windows-server/failover-clustering/failover-clustering-overview) provides high availability. Backups are separate. |

**Data:** files don't move by themselves. [Robocopy](https://learn.microsoft.com/windows-server/administration/windows-commands/robocopy) can copy them, or [Azure File Sync](https://learn.microsoft.com/azure/storage/file-sync/file-sync-introduction) can keep a Windows Server in step with the Azure file share while the link is up. Cloud tiering has to be off if the files must be readable without Azure.

## Sample

The [Order Management sample](../../samples/OrderManagementApp/README.md) archives each order as a JSON object: in Blob storage on Azure and in SeaweedFS on Azure Local, where SeaweedFS also holds the PostgreSQL backups. [SeaweedFS as an alternative](./alternatives/seaweedfs.md#how-the-order-management-sample-does-it) links the code for each change above. The sample doesn't use Azure Files.
