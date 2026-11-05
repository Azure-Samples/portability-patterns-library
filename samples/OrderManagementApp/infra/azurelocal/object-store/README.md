# Object storage for Azure Local

[SeaweedFS](https://github.com/seaweedfs/seaweedfs) runs in the cluster as an S3-compatible store.
It holds the app's buckets (the processor archives every order to `oms-azurelocal.orders`) and,
with `Availability` `high`, the PostgreSQL backups.

| File | What it is |
| --- | --- |
| [values.yaml](./values.yaml) | SeaweedFS: 3 masters, 3 volume servers keeping 2 copies of every object, 2 filers, 2 S3 gateways, encrypted. One of each with `standard` |
| [network-policy.yaml](./network-policy.yaml) | Only the store's clients may reach it, over HTTPS |
| [pod-disruption-budgets.yaml](./pod-disruption-budgets.yaml) | A node drain takes one pod of each component at a time |

[provision-object-store.ps1](../../../scripts/infra/azurelocal/provision-object-store.ps1), the
`ObjectStore` setup step, installs it and creates S3 identities, each limited to its own buckets:

| For | May use | Keys in Secret |
| --- | --- | --- |
| Apps in a namespace | buckets `<namespace>.*` | `object-store-credentials` |
| Databases in a namespace | bucket `postgres-<namespace>` | `backup-object-store` |

Clients connect to `https://seaweedfs-s3.object-store.svc.cluster.local:8443` with a certificate
from the site CA. To change a namespace's keys with no downtime, run
[rotate-credentials.ps1](../../../scripts/infra/azurelocal/rotate-credentials.ps1)
`-Credential object-store` or `backup-object-store`.

## For production

- **Copy data off the cluster.** The store protects against a failed node or pod, not losing the
  cluster. Copy the buckets to another site, for example with `weed filer.remote.sync`.
- **Size:** 10 GB per volume server by default, about 15 GB of data with two copies. Set
  `StorageSize` from your data.