using Azure.Core;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// Entra ID token for one resource (<c>Inventory__Scope</c>, for example
/// <c>api://&lt;client-id&gt;/.default</c>) from the pod's workload identity. Azure.Identity caches
/// the token and renews it before it expires.
/// </summary>
public sealed class EntraServiceTokenProvider(TokenCredential credential, string? scope) : IServiceTokenProvider
{
    public async Task<string?> GetAccessTokenAsync(CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(scope))
        {
            throw new InvalidOperationException(
                "The pod has an Entra workload identity but no scope to request a token for. Set Inventory__Scope.");
        }

        var token = await credential.GetTokenAsync(new TokenRequestContext([scope]), cancellationToken)
            .ConfigureAwait(false);
        return token.Token;
    }
}
