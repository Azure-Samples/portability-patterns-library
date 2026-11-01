namespace OrderManagement.Shared.Identity;

/// <summary>
/// Supplies this workload's own access token for calls to other services. Which issuer mints it
/// (Entra ID, Keycloak, or none locally) is decided by what the platform gave the pod.
/// </summary>
public interface IServiceTokenProvider
{
    /// <returns>A bearer token, or null where calls go without one (local compose).</returns>
    Task<string?> GetAccessTokenAsync(CancellationToken cancellationToken);
}
