namespace OrderManagement.Shared.Identity;

/// <summary>
/// Supplies the credential a service connects to its database with: a password the platform
/// injected, or an Entra ID access token from the pod's workload identity.
/// </summary>
public interface IDatabaseCredentialProvider
{
    /// <summary>For logs; never contains the secret.</summary>
    string Description { get; }

    /// <summary>The database principal to sign in as; null where the token alone identifies it (SQL).</summary>
    string? UserName { get; }

    /// <summary>
    /// Called for every new physical connection: tokens expire, so one is never cached here beyond
    /// what the token credential itself caches.
    /// </summary>
    Task<DatabaseCredential> GetCredentialAsync(CancellationToken cancellationToken);
}
