namespace OrderManagement.Shared.Identity;

/// <summary>No identity for service calls: local compose, where the services trust each other.</summary>
public sealed class NoServiceTokenProvider : IServiceTokenProvider
{
    public Task<string?> GetAccessTokenAsync(CancellationToken cancellationToken) => Task.FromResult<string?>(null);
}
