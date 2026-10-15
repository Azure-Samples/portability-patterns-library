using Azure.Core;
using Azure.Identity;

namespace Bcd.Shared.Identity;

/// <summary>
/// Builds the <see cref="TokenCredential"/> used for every Azure data plane call.
///
/// On AKS (and any cluster wired for Microsoft Entra Workload Identity) the pod's service account
/// is annotated with the client ID of a user-assigned managed identity, and a federated identity
/// credential (FIC) on that identity trusts the cluster's OIDC issuer for that service account
/// subject. The kubelet projects a service account token into the pod at
/// <c>AZURE_FEDERATED_TOKEN_FILE</c>; <see cref="WorkloadIdentityCredential"/> exchanges it for an
/// Entra ID access token. No secrets are ever stored in the cluster.
///
/// Locally, where none of those variables are present, this falls back to
/// <see cref="DefaultAzureCredential"/> so a developer signed in with <c>az login</c> works too.
/// </summary>
public static class AzureCredentialFactory
{
    public static TokenCredential Create(string? workloadIdentityClientId)
    {
        var tokenFilePath = Environment.GetEnvironmentVariable("AZURE_FEDERATED_TOKEN_FILE");
        var tenantId = Environment.GetEnvironmentVariable("AZURE_TENANT_ID");
        var clientId = string.IsNullOrWhiteSpace(workloadIdentityClientId)
            ? Environment.GetEnvironmentVariable("AZURE_CLIENT_ID")
            : workloadIdentityClientId;

        if (!string.IsNullOrWhiteSpace(tokenFilePath) && !string.IsNullOrWhiteSpace(clientId))
        {
            return new WorkloadIdentityCredential(new WorkloadIdentityCredentialOptions
            {
                ClientId = clientId,
                TenantId = tenantId,
                TokenFilePath = tokenFilePath
            });
        }

        var options = new DefaultAzureCredentialOptions();
        if (!string.IsNullOrWhiteSpace(clientId))
        {
            options.ManagedIdentityClientId = clientId;
            options.WorkloadIdentityClientId = clientId;
        }

        return new DefaultAzureCredential(options);
    }
}
