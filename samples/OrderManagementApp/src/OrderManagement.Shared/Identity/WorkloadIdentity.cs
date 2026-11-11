using Azure.Core;
using Azure.Identity;
using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// The workload identity the platform gave this pod, if any. On Azure, Entra Workload ID sets
/// <c>AZURE_CLIENT_ID</c>, <c>AZURE_TENANT_ID</c> and <c>AZURE_FEDERATED_TOKEN_FILE</c>. On Azure Local,
/// the Recipe Pack sets <c>IDENTITY_CLIENT_ID</c>, <c>IDENTITY_TOKEN_ENDPOINT</c> and
/// <c>IDENTITY_TOKEN_FILE</c> for Keycloak the same way. In both, the pod's ServiceAccount token is
/// exchanged for an access token: there is no stored secret.
/// </summary>
public sealed record WorkloadIdentity(EntraWorkloadIdentity? Entra, KeycloakWorkloadIdentity? Keycloak)
{
    public static WorkloadIdentity FromConfiguration(IConfiguration configuration)
    {
        string? Value(string key) => string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key];

        var entra = Value("AZURE_CLIENT_ID") is not null && Value("AZURE_FEDERATED_TOKEN_FILE") is not null
            ? new EntraWorkloadIdentity(new WorkloadIdentityCredential())
            : null;

        var keycloak = (Value("IDENTITY_CLIENT_ID"), Value("IDENTITY_TOKEN_ENDPOINT"), Value("IDENTITY_TOKEN_FILE")) is
            ({ } clientId, { } tokenEndpoint, { } tokenFile)
            ? new KeycloakWorkloadIdentity(clientId, new Uri(tokenEndpoint), tokenFile)
            : null;

        return new WorkloadIdentity(entra, keycloak);
    }
}

/// <summary>
/// Entra Workload ID, one credential for every Azure client in the process.
/// <see cref="WorkloadIdentityCredential"/> reads the <c>AZURE_*</c> variables itself, caches tokens and
/// renews them before they expire.
/// </summary>
public sealed record EntraWorkloadIdentity(TokenCredential Credential);

/// <param name="ClientId">The Keycloak client the workload signs in as.</param>
/// <param name="TokenEndpoint">The realm's token endpoint.</param>
/// <param name="AssertionFile">The projected ServiceAccount token, sent as the client assertion.</param>
public sealed record KeycloakWorkloadIdentity(string ClientId, Uri TokenEndpoint, string AssertionFile)
{
    /// <summary>The Duende client credentials client the token is requested and cached under.</summary>
    public const string ClientName = "workload";
}
