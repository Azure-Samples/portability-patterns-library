# Object storage for Azure Local

On Azure, the app archives orders to Blob Storage. On Azure Local it uses
[SeaweedFS](https://github.com/seaweedfs/seaweedfs), an S3-compatible store that runs in the cluster.
With `Availability` `high` it also holds the PostgreSQL backups.

With `high`, every object is kept twice, on different nodes, so losing a node loses no data;
`standard` keeps one copy. Data is encrypted at rest, and only the services that use the store can
reach it, over HTTPS.

| File | What it is |
| --- | --- |
| [values.yaml](./values.yaml) | The store's settings: copies, encryption, HTTPS |
| [network-policy.yaml](./network-policy.yaml) | Lets in only the store's clients |
| [pod-disruption-budgets.yaml](./pod-disruption-budgets.yaml) | Keeps the store serving while a node is drained |

The `ObjectStore` setup step ([provision-object-store.ps1](../../../scripts/infra/azurelocal/provision-object-store.ps1))
installs it. Each namespace gets its own keys, which work only on that namespace's buckets: the
app's are in Secret `object-store-credentials`, the database backups' in `backup-object-store`. To
change them with no downtime, run
[rotate-credentials.ps1](../../../scripts/infra/azurelocal/rotate-credentials.ps1)
`-Credential object-store` or `-Credential backup-object-store`.

## For production

- **Copy data off the cluster.** The store survives a failed node, not a lost cluster. Copy the
  buckets to another site, for example with `weed filer.remote.sync`.
- **Size:** each of the three storage nodes has 10 GB by default, so about 15 GB of data fits with
  two copies. Set `StorageSize` from your data.
