using Duende.AccessTokenManagement;
using OrderManagement.Shared.Identity;
using RabbitMQ.Client;

namespace OrderManagement.Shared.Messaging;

/// <summary>
/// The workload's Keycloak access token as RabbitMQ credentials. RabbitMQ's OAuth 2.0 backend takes
/// the token as the password and ignores the user name. The connection asks for credentials when it
/// connects and recovers; <see cref="RabbitMQ.Client.OAuth2.CredentialsRefresher"/> asks again before
/// the token expires and hands the new one to the open connection.
/// </summary>
internal sealed class KeycloakCredentialsProvider(IClientCredentialsTokenManager tokens, TimeProvider time) : ICredentialsProvider
{
    public string Name => KeycloakWorkloadIdentity.ClientName;

    public async Task<Credentials> GetCredentialsAsync(CancellationToken cancellationToken = default)
    {
        var result = await tokens.GetAccessTokenAsync(
            ClientCredentialsClientName.Parse(KeycloakWorkloadIdentity.ClientName), ct: cancellationToken).ConfigureAwait(false);
        if (!result.WasSuccessful(out var token, out var failure))
        {
            throw new InvalidOperationException($"No access token from Keycloak: {failure.Error}");
        }

        return new Credentials(Name, string.Empty, token.AccessToken.ToString(), token.Expiration - time.GetUtcNow());
    }
}
