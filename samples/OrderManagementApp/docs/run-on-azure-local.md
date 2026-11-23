# Running on Azure Local

## When the link to Azure is down

The app keeps serving users: images come from the in-cluster registry, users sign in through
Keycloak and Active Directory, cert-manager renews certificates from the site CA, and credentials
live in the cluster.

Installing and upgrading need the link (Helm charts, operator manifests, new images), so plan them
for when the site is connected. Azure Local must connect at least once every 30 days; past that,
running VMs keep running but nothing can be created or changed.

## Availability

| | `high` (default) | `standard` |
|---|---|---|
| RabbitMQ | three nodes ([operator](../infra/azurelocal/operators/README.md)) | one broker |
| PostgreSQL | primary and two replicas, backed up to the object store | one server, no backups |
| Object store | replicated across workers | one server of each kind |
| Workers | three, 4 vCPU / 16 GB | three, 4 vCPU / 8 GB |

Set it once, as `Common.Availability`, before the first deployment.

## Credentials

Database passwords and object store keys are generated on site and kept only in the cluster, as
Kubernetes Secrets. To change one:

```powershell
# sql-api-password, sql-processor-password, postgres-inventory-password, sql-admin-password,
# postgres-admin-password, object-store or backup-object-store
./scripts/infra/azurelocal/rotate-credentials.ps1 -KubeContext <context> -Credential sql-api-password
```

A service briefly fails requests while it restarts with a new database password; an object store
key changes with no downtime. To bring a secret that already lives in Azure to the site, keep it in
Key Vault and sync it as [key-vault-sync.yaml](../infra/azurelocal/key-vault-sync.yaml) shows.

## For production

See the production list in the [README](../README.md#deploy-to-azure-local).
