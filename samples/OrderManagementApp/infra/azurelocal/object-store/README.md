# Object storage for Azure Local

[SeaweedFS](https://github.com/seaweedfs/seaweedfs) (Apache 2.0) runs in the cluster as an
S3-compatible object store, and keeps working when the link to Azure is down. It holds:

- **the applications' object storage:** the Recipe for `Radius.Storage/objectStorage`
  ([seaweedfs-objectstorage.bicep](../../../../../recipes/object-storage/azure-local/seaweedfs/seaweedfs-objectstorage.bicep))
  gives each resource a bucket here, named `<namespace>.<containerName>`. The Order Management
  processor archives every order to `oms-azurelocal.orders`;
- **PostgreSQL backups,** with `Common.Availability` `high`: CloudNativePG's Barman Cloud plugin
  archives every write-ahead log segment and takes a daily base backup, so a database can be
  restored to any point in its retention window (30 days by default).

| File | What it is |
| --- | --- |
| [values.yaml](./values.yaml) | SeaweedFS replicated (3 masters, 3 volume servers keeping 2 copies of every object, 2 filers, 2 S3 gateways, each on its own node) and encrypted. With `standard`, [provision-object-store.ps1](../../../scripts/infra/azurelocal/provision-object-store.ps1) runs one of each, keeping one copy |
| [network-policy.yaml](./network-policy.yaml) | Only the store's clients may reach it, and only over HTTPS |

Nothing reaches or leaves the store in the clear:

- clients connect to `https://seaweedfs-s3.object-store.svc.cluster.local:8443`, whose certificate
  comes from the site CA; the app's pods trust that CA, and the databases get it in their Secret;
- the store's components talk to each other over mutual TLS, with certificates cert-manager issues
  from the store's own CA;
- the S3 gateways encrypt every chunk of an object before it goes to a volume server, so the volume
  servers, and their disks, only ever hold ciphertext.

[provision-object-store.ps1](../../../scripts/infra/azurelocal/provision-object-store.ps1) installs
it into namespace `object-store`, after the operators, and creates S3 identities, each limited to
its own buckets, with keys generated once:

| For | Identity may | Its keys, in Secret |
| --- | --- | --- |
| Applications in `oms-azurelocal` | create and use buckets `oms-azurelocal.*` | `object-store-credentials` there, keys `ACCESSKEYID` and `SECRETACCESSKEY` |
| Databases in `oms-azurelocal` and `identity` | use bucket `postgres-<namespace>` | `backup-object-store` there, keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`, with the CA to verify the store, `ca.crt` |

The Recipe Pack gives an application's keys only to containers connected to object storage, as
`CONNECTION_<NAME>_ACCESSKEYID` and `_SECRETACCESSKEY`, and labels their pods
`object-store/client: "true"`, which the network policy lets in. The identities go to SeaweedFS in
Secret `object-store/object-store-s3-config`, key `seaweedfs_s3_config`. Namespace names can't
contain a dot, so one namespace's `<namespace>.*` never matches another's buckets, nor the backup
buckets:

```json
{
  "identities": [
    {
      "name": "objects-oms-azurelocal",
      "credentials": [ { "accessKey": "<generated>", "secretKey": "<generated>" } ],
      "actions": [ "Admin:oms-azurelocal.*" ]
    },
    {
      "name": "postgres-oms-azurelocal",
      "credentials": [ { "accessKey": "<generated>", "secretKey": "<generated>" } ],
      "actions": [ "Read:postgres-oms-azurelocal", "Write:postgres-oms-azurelocal", "List:postgres-oms-azurelocal", "Tagging:postgres-oms-azurelocal" ]
    }
  ]
}
```

## What it survives

| Failure | What happens |
| --- | --- |
| A master | The other two keep a majority and carry on. |
| A volume server | Reads come from the other copy; new objects go to the two volume servers left. |
| A filer or an S3 gateway | The other one carries on, and the S3 Service sends requests to it. |

It needs at least three nodes: the masters must each be on a different node, and so must the volume
servers.

## For production

- **Copy data off the cluster.** The store is in the same cluster as what it holds, so it protects
  against a failed node or pod, a deleted object or table, not against losing the cluster or its
  storage. Copy the buckets to another site, for example with `weed filer.remote.sync` to Azure Blob
  Storage or another S3 store while the link is up.
- **Size:** 20 GB per volume server by default; with two copies of everything on three servers, that
  holds about 30 GB. Grow `StorageSize` with the data: base backups are compressed copies of each
  database, plus every WAL segment in the retention window.
