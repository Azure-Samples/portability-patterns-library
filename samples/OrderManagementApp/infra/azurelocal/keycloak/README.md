# Keycloak for Azure Local

Keycloak is the sign-in and token service on site. It reads users and groups from your Active
Directory, so it keeps working when the link to Azure is down. On Azure, Microsoft Entra ID does
this job.

| File | What it is |
| --- | --- |
| [keycloak.yaml](./keycloak.yaml) | Keycloak and its PostgreSQL database |
| [realm.json](./realm.json) | The `oms` realm: AD connection, app roles, sign-in and workload clients |
| [realm-settings.env](./realm-settings.env) | Your site's values for the `${...}` placeholders in `realm.json` |
| [kustomization.yaml](./kustomization.yaml) | Puts it together, and sets the image tags |

## Before you start

- The `oms-app-readers` and `oms-app-writers` groups and a read-only bind account exist in AD.
  See [Connect your Active Directory](../../../docs/authentication.md#connect-your-active-directory).
- The directory's CA certificate, if you connect over LDAPS (recommended).

## Deploy by hand

Run these from the `samples/OrderManagementApp` folder.

1. Create the namespace and the secrets. Pick your own passwords.

   ```powershell
   kubectl create namespace identity
   kubectl -n identity create secret generic keycloak-admin --from-literal=username=admin --from-literal=password=<admin-password>
   kubectl -n identity create secret generic keycloak-db --from-literal=username=keycloak --from-literal=password=<db-password>
   kubectl -n identity create secret generic oms-ad-bind --from-literal=bind-upn=<bind-account-upn> --from-literal=bind-password=<bind-password>
   kubectl -n identity create secret generic oms-ad-ca --from-file=ca.crt=<directory-ca.crt>
   ```

2. Give Keycloak the cluster's CA, so it can check service account tokens:

   ```powershell
   kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' > ca.b64
   [IO.File]::WriteAllBytes("$PWD/cluster-ca.pem", [Convert]::FromBase64String((Get-Content ca.b64)))
   kubectl -n identity create secret generic cluster-ca --from-file=cluster-ca.pem
   ```

3. Give Keycloak a TLS certificate with the node address and `keycloak.identity.svc` in its names.
   With cert-manager and the site's ClusterIssuer from
   [provision-ingress.ps1](../../../scripts/infra/azurelocal/provision-ingress.ps1), create a
   `Certificate` for Secret `keycloak-tls` (as [keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1)
   does), and it's renewed before it expires. Or supply one your site's CA issued, which you then
   renew yourself:

   ```powershell
   kubectl -n identity create secret tls keycloak-tls --cert <keycloak.crt> --key <keycloak.key>
   ```

4. Fill in [realm-settings.env](./realm-settings.env), then create the settings:

   ```powershell
   kubectl -n identity create configmap keycloak-realm-settings --from-env-file=infra/azurelocal/keycloak/realm-settings.env
   ```

5. Deploy:

   ```powershell
   kubectl apply -k infra/azurelocal/keycloak
   kubectl -n identity rollout status deployment keycloak --timeout=10m
   ```

6. Check it. The realm is at `https://<node address>:30443/realms/oms`. Sign in to the admin
   console at `https://<node address>:30443/admin` with the `keycloak-admin` password, then open
   **oms** > **User federation** > **active-directory** and select **Sync all users**.

If the cluster pulls images from your own registry, such as an ACR connected registry, set the
images first. For example:
`kustomize edit set image quay.io/keycloak/keycloak=<registry>/keycloak/keycloak:26.8`.
Also add the `azurelocal-registry` pull secret to the `identity` namespace.

## Or use the script

[keycloak.ps1](../../../scripts/infra/azurelocal/keycloak.ps1) does all of the steps above. It
generates the passwords, gets the certificate from the site's ClusterIssuer and fills in the
settings from the cluster. It also prepares the app's namespace.

## Changing the realm

Keycloak imports `realm.json` only when the `oms` realm doesn't exist yet. To apply a change, delete
the realm in the admin console and restart Keycloak, or run the script with `-ReimportRealm`.
The new realm has new signing keys, so restart the app's pods afterwards.
