using Azure.Core;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// An Entra ID access token from the pod's workload identity, as on Azure. Azure.Identity caches
/// the token and fetches a new one before it expires, so asking on every connection is cheap.
/// </summary>
public sealed class EntraTokenCredentialProvider(TokenCredential credential, string scope, string? userName)
    : IDatabaseCredentialProvider
{
    public string Description => userName is null
        ? "Entra ID token from the workload identity"
        : $"Entra ID token from the workload identity as '{userName}'";

    public string? UserName => userName;

    public async Task<DatabaseCredential> GetCredentialAsync(CancellationToken cancellationToken)
    {
        var token = await credential.GetTokenAsync(new TokenRequestContext([scope]), cancellationToken)
            .ConfigureAwait(false);
        return new DatabaseCredential(userName, token.Token, IsAccessToken: true);
    }
}
