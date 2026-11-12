using Duende.AccessTokenManagement;
using Duende.IdentityModel;
using Duende.IdentityModel.Client;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// The client assertion for Keycloak: the pod's projected ServiceAccount token, read on every token
/// request because the kubelet replaces the file before the token in it expires.
/// </summary>
internal sealed class ServiceAccountTokenAssertion(KeycloakWorkloadIdentity identity) : IClientAssertionService
{
    public async Task<ClientAssertion?> GetClientAssertionAsync(
        ClientCredentialsClientName? clientName = null,
        TokenRequestParameters? parameters = null,
        CancellationToken ct = default) => new()
        {
            Type = OidcConstants.ClientAssertionTypes.JwtBearer,
            Value = (await File.ReadAllTextAsync(identity.AssertionFile, ct).ConfigureAwait(false)).Trim()
        };
}
