# Keycloak for Azure Local

Keycloak is the sign-in and token service on site, federated to your Active Directory, so sign-in
keeps working when the link to Azure is down. On Azure, Microsoft Entra ID does this job. Two
replicas share their sessions; their database fails over and is backed up with `Availability`
`high`, and is a single server with `standard`.

| File | What it is |
| --- | --- |
| [keycloak.yaml](./keycloak.yaml) | Keycloak: two replicas and a disruption budget |
| [realm.json](./realm.json) | The `oms` realm: AD connection, app roles, sign-in and workload clients |
| [realm-config.yaml](./realm-config.yaml) | A Job that applies `realm.json` with [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli) on every deployment |
| [realm-settings.env](./realm-settings.env) | Your site's values for the `${...}` placeholders in `realm.json` |
| [database/](./database/) | Its database: `cloudnative-pg.yaml` for `high`, `postgres.yaml` for `standard` |
| [service.yaml](./service.yaml) | Its address on the site network, from the Arc load balancer |

## Deploy

[keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1), the `Keycloak` step of
`setup-platform.ps1`, does everything: secrets, address, TLS certificates from the site CA, realm
settings, images from the site's registry. Before it runs you need the AD groups and a read-only
bind account ([Connect your Active Directory](../../../docs/authentication.md#connect-your-active-directory)),
the directory's CA certificate for LDAPS, and the `Operators` and `ObjectStore` steps with `high`.

Check it by signing in to `https://<address>/realms/oms/account` with a directory account.

## Changing the realm

`realm.json` and `realm-settings.env` are the source of truth: change them and run `keycloak.ps1`
again. Changes made in the admin console to anything `realm.json` defines are undone by the next run.

## Admin access

There's no admin user. The admin console is served only on `https://localhost:8443`; members of
the AD group `oms-identity-admins` administer the `oms` realm with their own accounts:

```powershell
kubectl -n identity port-forward service/keycloak 8443:443
# then open https://localhost:8443/admin/oms/console/
```

To recover the master realm, see Keycloak's
[admin recovery guide](https://www.keycloak.org/server/bootstrap-admin-recovery).

## Sign-in protection

Keycloak locks an account for 15 minutes after 3 failed sign-ins, so password guessing never
reaches your domain's lockout threshold. Keep `failureFactor` in `realm.json` below that threshold.