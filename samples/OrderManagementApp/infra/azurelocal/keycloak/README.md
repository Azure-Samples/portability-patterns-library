# Keycloak for Azure Local

Keycloak is the sign-in and token service on site. It reads users and groups from your Active
Directory, so it keeps working when the link to Azure is down. On Azure, Microsoft Entra ID does
this job. Two replicas run on separate nodes and share their sessions. With `Common.Availability`
`high` (the default) their database is a PostgreSQL cluster that fails over and backs up, so sign-in
survives losing a node; with `standard` it's one PostgreSQL server with no backups.

| File | What it is |
| --- | --- |
| [keycloak.yaml](./keycloak.yaml) | Keycloak: two replicas, and a disruption budget that keeps one serving |
| [database/cloudnative-pg.yaml](./database/cloudnative-pg.yaml) | Its database with `high`: a two-instance CloudNativePG cluster, backed up to the site's object store |
| [database/postgres.yaml](./database/postgres.yaml) | Its database with `standard`: one PostgreSQL server in a StatefulSet, TLS from the site CA |
| [service.yaml](./service.yaml) | Its address on the site network, from the Arc load balancer |
| [realm.json](./realm.json) | The `oms` realm: AD connection, app roles, sign-in and workload clients |
| [realm-settings.env](./realm-settings.env) | Your site's values for the `${...}` placeholders in `realm.json` |
| [kustomization.yaml](./kustomization.yaml) | Puts Keycloak together, and sets the image tags |

## Before you start

- The `oms-app-readers` and `oms-app-writers` groups and a read-only bind account exist in AD.
  See [Connect your Active Directory](../../../docs/authentication.md#connect-your-active-directory).
- The directory's CA certificate, if you connect over LDAPS (recommended).
- With `high`: the CloudNativePG operator and the site's object store, with Secret
  `identity/backup-object-store` for the database's backups: the `Operators` and `ObjectStore` steps
  ([operators](../operators/README.md), [object store](../object-store/README.md)).
- With `standard`: Secret `identity/keycloak-db-tls`, a certificate for `keycloak-db-rw.identity.svc`
  from the site CA, issued like Keycloak's in step 4.

## Deploy by hand

Run these from the `samples/OrderManagementApp` folder.

1. Create the namespace and the secrets. Pick your own passwords.

   ```powershell
   kubectl create namespace identity
   kubectl -n identity create secret generic keycloak-admin --from-literal=username=admin --from-literal=password=<admin-password>
   kubectl -n identity create secret generic keycloak-db --type=kubernetes.io/basic-auth --from-literal=username=keycloak --from-literal=password=<db-password>
   kubectl -n identity create secret generic oms-ad-bind --from-literal=bind-upn=<bind-account-upn> --from-literal=bind-password=<bind-password>
   kubectl -n identity create secret generic oms-ad-ca --from-file=ca.crt=<directory-ca.crt>
   kubectl -n identity create secret generic grafana-oauth --from-literal=client-id=grafana --from-literal=client-secret=<random-secret>
   ```

2. Give Keycloak the cluster's CA, so it can check service account tokens:

   ```powershell
   kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' > ca.b64
   [IO.File]::WriteAllBytes("$PWD/cluster-ca.pem", [Convert]::FromBase64String((Get-Content ca.b64)))
   kubectl -n identity create secret generic cluster-ca --from-file=cluster-ca.pem
   ```

3. Give Keycloak its address. The Arc load balancer gives the Service the first free address of its
   range; pin it so it stays:

   ```powershell
   kubectl apply -f infra/azurelocal/keycloak/service.yaml
   $address = kubectl -n identity get service keycloak -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   kubectl -n identity annotate service keycloak "metallb.io/loadBalancerIPs=$address"
   ```

4. Give Keycloak a TLS certificate with that address and `keycloak.identity.svc` in its names.
   With cert-manager and the site's ClusterIssuer from
   [provision-ingress.ps1](../../../scripts/infra/azurelocal/provision-ingress.ps1), create a
   `Certificate` for Secret `keycloak-tls` (as [keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1)
   does), and it's renewed before it expires. Or supply one your site's CA issued, which you then
   renew yourself:

   ```powershell
   kubectl -n identity create secret tls keycloak-tls --cert <keycloak.crt> --key <keycloak.key>
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
   ```

   With `standard`, apply `database/postgres.yaml` instead, and wait with
   `kubectl -n identity rollout status statefulset keycloak-db`.

7. Check it. The realm is at `https://<address>/realms/oms`. Sign in to the admin console at
   `https://<address>/admin` with the `keycloak-admin` password, then open **oms** >
   **User federation** > **active-directory** and select **Sync all users**.

If the cluster pulls images from your own registry, such as an ACR connected registry, set the
images first. For example:
`kustomize edit set image quay.io/keycloak/keycloak=<registry>/keycloak/keycloak:26.8`, and the
database's image in [database/](./database/). Also add the `azurelocal-registry` pull secret to
the `identity` namespace.

## Or use the script

[keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1) does all of the steps above. It
generates the passwords, keeps Keycloak's address, gets the certificate from the site's
ClusterIssuer and fills in the settings from the cluster. It also prepares the app's namespace.

## Changing the realm

Keycloak imports `realm.json` only when the `oms` realm doesn't exist yet. To apply a change, delete
the realm in the admin console and restart Keycloak. The new realm has new signing keys, so restart
the app's pods afterwards.
