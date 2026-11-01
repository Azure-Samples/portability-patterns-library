namespace OrderManagement.Shared.Identity;

/// <summary>
/// A database login with a password, as on Azure Local (from a Kubernetes Secret synced from Key
/// Vault) and in local compose.
/// </summary>
public sealed class PasswordCredentialProvider(string userName, string password) : IDatabaseCredentialProvider
{
    public string Description => $"password login '{userName}'";

    public string? UserName => userName;

    public Task<DatabaseCredential> GetCredentialAsync(CancellationToken cancellationToken) =>
        Task.FromResult(new DatabaseCredential(userName, password, IsAccessToken: false));
}
