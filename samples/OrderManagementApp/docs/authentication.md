# How authentication works

There are two kinds of authentication: **users** signing in to the app, and the **app's own pods**
signing in to the queue, storage and SQL. Paths are relative to the sample folder,
[samples/OrderManagementApp](../).

## Users

The app is written once, for Microsoft Entra ID: MSAL.js in the browser
([app.js](../src/OrderManagement.Api/wwwroot/js/app.js)) and Microsoft.Identity.Web in the API
([Program.cs](../src/OrderManagement.Api/Program.cs)). On Azure Local, Keycloak issues tokens shaped
like Entra's, so the code doesn't change.

1. The browser loads `/config.json` from the API: which identity provider, client ID and scope to use.
2. MSAL.js sends the user to Entra ID, or to Keycloak, which checks the password against Active
   Directory.
3. The browser calls `/api/...` with the access token.
4. The API checks the token (issuer, audience, scope `access_as_user`), then its `roles` claim:
   `Orders.Read` to list orders, `Orders.Create` to place one
   ([OrderAuthorization.cs](../src/OrderManagement.Api/OrderAuthorization.cs)).

Only settings differ: the `apiAuthentication` and `spaSettings` parameters of
[app.bicep](../deploy/app.bicep). The registrations behind them are in
[app-identity.bicep](../infra/azure/app-identity.bicep) for Entra and
[realm.json](../infra/azurelocal/keycloak/realm.json) for Keycloak.

## Workloads

The pods hold no secrets where the platform can give them an identity. The code picks its
credential from what the platform provides, with no platform switch:

| Service | Azure | Azure Local | Where the choice is made |
|---|---|---|---|
| Queue | [Entra Workload ID](https://learn.microsoft.com/azure/aks/workload-identity-overview) | the pod's Kubernetes token, exchanged at Keycloak for a token RabbitMQ accepts | [ServiceCollectionExtensions.cs](../src/OrderManagement.Shared/DependencyInjection/ServiceCollectionExtensions.cs) |
| Object storage | Entra Workload ID | Azurite connection string from the Recipe | [ArchiveOptions.cs](../src/OrderManagement.Shared/Configuration/ArchiveOptions.cs) |
| SQL | Entra Workload ID | SQL login (`sa`) with the password set at deployment | [SqlOptions.cs](../src/OrderManagement.Shared/Configuration/SqlOptions.cs) |

On Azure Local, Keycloak plays Entra's part: it trusts the cluster's token issuer, the way Entra
trusts it through a federated credential, so the exchange works the same way and needs nothing in
Azure.

| | Azure | Azure Local |
|---|---|---|
| Trusts the pod's token | Entra, through a federated identity credential | Keycloak client `oms-workloads` (`federated-jwt`) |
| Puts the token in the pod | Workload ID webhook | the Recipe Pack, through the container Recipe |
| Tells the app where to use it | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE` | `IDENTITY_CLIENT_ID`, `IDENTITY_TOKEN_ENDPOINT`, `IDENTITY_TOKEN_FILE`, set by the Recipe Pack |
| Checks permissions | Azure RBAC | the `rabbitmq_scopes` claim in the token |

If RabbitMQ refuses the token, check these first:

| Symptom | Cause |
|---|---|
| Keycloak reports a signature validation failure | Keycloak can't read the cluster's signing keys; it needs the `system:service-account-issuer-discovery` role. |
| `client_not_found` from Keycloak | The realm's client authentication flow lacks `federated-jwt` (realms migrated from before Keycloak 26.8). |
| `Bad Certificate - selfsigned_peer` in the RabbitMQ log | Keycloak's certificate must come from a CA, not be self-signed. |

## Connect your Active Directory

On Azure Local, users and their roles come from Active Directory through Keycloak. The directory
needs:

- An OU for the app, `OMS`. Keycloak reads users and groups only from it.
- Two groups in it: `oms-app-readers` (`Orders.Read`) and `oms-app-writers` (`Orders.Create`).
  Granting access is adding people to these groups.
- A bind account for Keycloak, `svc-keycloak`, limited to what Keycloak does: sign in to a domain
  controller over LDAP and read the users and groups in the OU. It's in no group, can sign in only
  at the domain controllers, can't be delegated, and is denied listing every container outside the
  OU. Keycloak's connection is read-only too, so it never writes to the directory.
- LDAPS on the domain controller, which needs a server certificate from a certificate authority.

[ad-setup.ps1](../scripts/infra/azurelocal/ad-setup.ps1) creates all of this and hands the bind
account and the CA certificate to the cluster. Run it from the management machine as a
domain administrator:

```powershell
./scripts/infra/azurelocal/ad-setup.ps1 -ComputerName <domain controller> -DomainName <domain> `
    -NetbiosName <NETBIOS name> -KubeContext <cluster context>
```

The listing limits cover the containers and domain controllers that exist when the script runs, so
run it again after adding either. That resets the bind password, so then run `keycloak.ps1
-ReimportRealm` and restart the app's pods.
Some things stay readable, as they are for every account in the domain: the names of the containers
directly under the domain root (Keycloak has to find the OU there), the sub-containers of Group
Policy objects, the forest's configuration, schema and DNS partitions, and the domain controllers'
SYSVOL share.

To create the objects yourself instead, give the bind account the same limits, then give Keycloak
the bind account and the CA's root certificate as Secrets:

```powershell
kubectl create namespace identity
kubectl -n identity create secret generic oms-ad-bind `
    --from-literal=bind-upn=svc-keycloak@<domain> --from-literal=bind-password=<password>
kubectl -n identity create secret generic oms-ad-ca --from-file=ca.crt=<path to ca.crt>
```

To use an OU other than `OMS`, pass its name to `keycloak.ps1 -AdOuName`.
