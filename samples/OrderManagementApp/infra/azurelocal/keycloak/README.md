# Keycloak for Azure Local

Keycloak is the sign-in and token service on site. It reads users and groups from your Active
Directory, so it keeps working when the link to Azure is down. On Azure, Microsoft Entra ID does
this job. Two replicas run on separate nodes and share their sessions. With `Common.Availability`
`high` (the default) their database is a PostgreSQL cluster that fails over and backs up, so sign-in
survives losing a node; with `standard` it's one PostgreSQL server with no backups.

| File | What it is |
| --- | --- |
| [keycloak.yaml](./keycloak.yaml) | Keycloak: two replicas, and a disruption budget that keeps one serving |
| [realm.json](./realm.json) | The `oms` realm: AD connection, app roles, sign-in and workload clients |
| [realm-config.yaml](./realm-config.yaml) | A Job that applies `realm.json` with [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli) on every deployment |
| [realm-settings.env](./realm-settings.env) | Your site's values for the `${...}` placeholders in `realm.json` |
| [database/cloudnative-pg.yaml](./database/cloudnative-pg.yaml) | Its database with `high`: a two-instance CloudNativePG cluster, backed up to the site's object store |
| [database/postgres.yaml](./database/postgres.yaml) | Its database with `standard`: one PostgreSQL server in a StatefulSet |
| [service.yaml](./service.yaml) | Its address on the site network, from the Arc load balancer |
| [kustomization.yaml](./kustomization.yaml) | Puts Keycloak together, and sets the image versions |

Keycloak checks its database's certificate against the CA that issued it (`sslmode=verify-full`),
and both databases refuse unencrypted connections.

## Before you start

- The `oms-app-readers`, `oms-app-writers`, `oms-inventory-admins` and `oms-identity-admins` groups
  and a read-only bind account exist in AD. See
  [Connect your Active Directory](../../../docs/authentication.md#connect-your-active-directory).
- The directory's CA certificate, if you connect over LDAPS (recommended).
- cert-manager and the site CA's ClusterIssuer, from
  [provision-ingress.ps1](../../../scripts/infra/azurelocal/provision-ingress.ps1), or certificates
  your site's CA issued.
- With `high`: the CloudNativePG operator and the site's object store, with Secret
  `identity/backup-object-store` for the database's backups: the `Operators` and `ObjectStore` steps
  ([operators](../operators/README.md), [object store](../object-store/README.md)).

## Deploy by hand

Run these in PowerShell from the `samples/OrderManagementApp` folder.

1. Create the namespace and the secrets. Values go to kubectl on stdin, never on its command line.

   ```powershell
   kubectl create namespace identity
   function Set-Secret($Name, $Data, $Type = 'Opaque') {
       @{ apiVersion = 'v1'; kind = 'Secret'; type = $Type; metadata = @{ name = $Name; namespace = 'identity' }; stringData = $Data } |
           ConvertTo-Json | kubectl apply -f -
   }
   $random = { [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) }
   # The temporary admin service account Keycloak creates on its first start, for realm-config.yaml.
   # Keycloak reads it only then, so never change it afterwards.
   Set-Secret keycloak-admin-client @{ 'client-id' = 'realm-config'; 'client-secret' = & $random }
   Set-Secret keycloak-db @{ username = 'keycloak'; password = & $random } 'kubernetes.io/basic-auth'
   Set-Secret grafana-oauth @{ 'client-id' = 'grafana'; 'client-secret' = & $random }
   $bind = Read-Host -AsSecureString 'Password of the bind account'
   Set-Secret oms-ad-bind @{ 'bind-upn' = '<bind-account-upn>'; 'bind-password' = [Net.NetworkCredential]::new('', $bind).Password }
   kubectl -n identity create secret generic oms-ad-ca --from-file=ca.crt=<directory-ca.crt>
   ```

2. Give Keycloak the cluster's CA, so it can check service account tokens:

   ```powershell
   kubectl get configmap kube-root-ca.crt -n default -o jsonpath='{.data.ca\.crt}' > cluster-ca.pem
   kubectl -n identity create secret generic cluster-ca --from-file=cluster-ca.pem
   ```

3. Give Keycloak its address. The Arc load balancer gives the Service the first free address of its
   range; pin it so it stays:

   ```powershell
   kubectl apply -f infra/azurelocal/keycloak/service.yaml
   $address = kubectl -n identity get service keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   kubectl -n identity annotate service keycloak "metallb.io/loadBalancerIPs=$address"
   ```

4. Give Keycloak and its database TLS certificates. Each Secret holds `tls.crt`, `tls.key` and
   `ca.crt`, the CA that issued it, which Keycloak and the realm Job check against:
   - `keycloak-tls`, with the address from step 3 (as an IP address entry), `keycloak.identity.svc`
     and `localhost` (for the admin console, see [Admin access](#admin-access)) in its names;
   - `keycloak-db-tls`, with `keycloak-db-rw` and `keycloak-db-rw.identity.svc` in its names. For
     `high`, label it `cnpg.io/reload` so CloudNativePG picks up a renewed one.

   With cert-manager and the site's ClusterIssuer, create a `Certificate` for each (as
   [keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1) does), and they're renewed before
   they expire. Or supply ones your site's CA issued, which you then renew yourself:

   ```powershell
   kubectl -n identity create secret generic keycloak-tls --type=kubernetes.io/tls --from-file=tls.crt=<crt> --from-file=tls.key=<key> --from-file=ca.crt=<ca>
   kubectl -n identity create secret generic keycloak-db-tls --type=kubernetes.io/tls --from-file=tls.crt=<db-crt> --from-file=tls.key=<db-key> --from-file=ca.crt=<ca>
   ```

5. Fill in [realm-settings.env](./realm-settings.env), with `KC_HOSTNAME=https://<address>`, then
   create the settings:

   ```powershell
   kubectl -n identity create configmap keycloak-realm-settings --from-env-file=infra/azurelocal/keycloak/realm-settings.env
   ```

6. Deploy, with the database file for your availability. With `high`:

   ```powershell
   kubectl apply -k infra/azurelocal/keycloak
   kubectl -n identity apply -f infra/azurelocal/keycloak/database/cloudnative-pg.yaml
   kubectl -n identity wait cluster.postgresql.cnpg.io/keycloak-db --for=condition=Ready --timeout=15m
   kubectl -n identity rollout status deployment keycloak --timeout=15m
   kubectl -n identity wait job/keycloak-realm-config --for=condition=complete --timeout=30m
   ```

   With `standard`, apply `database/postgres.yaml` instead, and wait with
   `kubectl -n identity rollout status statefulset keycloak-db`.

7. Check it. The realm is at `https://<address>/realms/oms`. Sign in to
   `https://<address>/realms/oms/account` with a directory account from the `OMS` OU. If the Job
   failed, its log says why: `kubectl -n identity logs job/keycloak-realm-config`.

If the cluster pulls images from your own registry, such as an ACR connected registry, point the
images at it first. In [kustomization.yaml](./kustomization.yaml), add `newName` to each entry, such
as `newName: <registry>/keycloak/keycloak`, and change the database's image in
[database/](./database/) the same way. Also add the `azurelocal-registry` pull secret to the
`identity` namespace.

## Or use the script

[keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1) does all of the steps above. It
generates the secrets, keeps Keycloak's address, gets both certificates from the site's
ClusterIssuer, fills in the settings from the cluster and points the images at the site's registry
with a kustomize overlay. It also prepares the app's namespace.

## Changing the realm

`realm.json` and `realm-settings.env` are the realm's source of truth. The realm Job applies them on
every deployment: it creates what's missing, updates what differs, and removes what it created
earlier that `realm.json` no longer has. So to change the app's address, the directory, the bind
password or anything in `realm.json`, change it and run `keycloak.ps1` again. By hand, update the
ConfigMap or Secret, then:

```powershell
kubectl -n identity delete job keycloak-realm-config --ignore-not-found
kubectl apply -k infra/azurelocal/keycloak
kubectl -n identity wait job/keycloak-realm-config --for=condition=complete --timeout=30m
```

Changes made in the admin console to anything `realm.json` defines are undone by the next run.
Keycloak reads `KC_HOSTNAME` only when it starts, so after changing it, also run
`kubectl -n identity rollout restart deployment keycloak` (`keycloak.ps1` does this for you).

## Admin access

There's no admin user. The master realm has only the temporary admin service account
`realm-config` that Keycloak creates on its first start, which the realm Job signs in with; its
secret is in Secret `identity/keycloak-admin-client`.

The admin console is served only for `https://localhost:8443` (`KC_HOSTNAME_ADMIN`), not on the site
address. People in the directory group `oms-identity-admins` administer the `oms` realm, and nothing
else, with their own directory accounts:

```powershell
kubectl -n identity port-forward service/keycloak 8443:443
# then open https://localhost:8443/admin/oms/console/
```

Keycloak doesn't refuse admin API calls on the site address; they still need an admin's token.
Blocking `/admin` there takes a reverse proxy in front of Keycloak. To recover the master realm, for
example if the admin service account's secret is lost, follow Keycloak's
[admin recovery guide](https://www.keycloak.org/server/bootstrap-admin-recovery): `kc.sh
bootstrap-admin` with Keycloak scaled to zero.

## Sign-in protection

Every failed sign-in with a directory account is a failed bind against Active Directory, so
Keycloak locks an account for 15 minutes after 3 failures (`failureFactor`, `waitIncrementSeconds`
in `realm.json`). That keeps password guessing from reaching your domain's lockout threshold. Keep
`failureFactor` below that threshold, and `waitIncrementSeconds` at least its observation window.

The browser app's client, `oms-spa`, accepts only `https://<app address>/` as redirect and
post-logout address, and offers no `offline_access`: its sessions end with the user's Keycloak
session.
