using System.Net.Http.Headers;
using Azure.Core;
using Azure.Identity;
using Duende.AccessTokenManagement;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// Adds the workload's Keycloak access token, which Duende.AccessTokenManagement requests, caches and
/// renews. A token that can't be had (Keycloak restarting, say) fails the request as a transport
/// error, so the resilience handler retries it and callers see the service as unavailable, rather
/// than sending the request without a token and getting a 401.
/// </summary>
internal sealed class KeycloakTokenHandler(IClientCredentialsTokenManager tokens) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var result = await tokens.GetAccessTokenAsync(
            ClientCredentialsClientName.Parse(KeycloakWorkloadIdentity.ClientName), ct: cancellationToken).ConfigureAwait(false);
        if (!result.WasSuccessful(out var token, out var failure))
        {
            throw new HttpRequestException($"No access token from Keycloak: {failure.Error}");
        }

        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.AccessToken.ToString());
        return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
}

/// <summary>
/// Adds the workload's Entra ID access token for <paramref name="scope"/>. Azure.Identity caches it and
/// renews it before it expires. As with Keycloak, a token that can't be had is a transport error.
/// </summary>
internal sealed class EntraTokenHandler(TokenCredential credential, string scope) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Azure.Core.AccessToken token;
        try
        {
            token = await credential.GetTokenAsync(new TokenRequestContext([scope]), cancellationToken).ConfigureAwait(false);
        }
        catch (AuthenticationFailedException ex)
        {
            throw new HttpRequestException($"No access token from Entra ID: {ex.Message}", ex);
        }

        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
}
