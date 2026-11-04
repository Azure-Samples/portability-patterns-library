using Azure.Core;
using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// How a service signs in to its database: with a password the platform injected (Azure Local, from
/// a Kubernetes Secret synced from Key Vault; local compose), or otherwise with an Entra ID token
/// from the pod's workload identity (Azure). Connection targets come from the <c>CONNECTION_*</c>
/// values; credentials never do.
/// </summary>
public sealed class DatabaseLogin
{
    public const string SqlScope = "https://database.windows.net/.default";
    public const string PostgresScope = "https://ossrdbms-aad.database.windows.net/.default";

    private readonly TokenCredential? _credential;
    private readonly string _scope;

    private DatabaseLogin(string? userName, string? password, TokenCredential? credential, string scope)
    {
        UserName = userName;
        Password = password;
        _credential = credential;
        _scope = scope;
    }

    /// <summary>The database principal; null for an Entra token on SQL, where the token alone identifies it.</summary>
    public string? UserName { get; }

    public string? Password { get; }

    public bool UsesToken => _credential is not null;

    public async Task<AccessToken> GetTokenAsync(CancellationToken cancellationToken) =>
        await (_credential ?? throw new InvalidOperationException("This login uses a password."))
            .GetTokenAsync(new TokenRequestContext([_scope]), cancellationToken).ConfigureAwait(false);

    // For logs: never the secret.
    public override string ToString() => UsesToken
        ? UserName is null ? "an Entra ID token" : $"an Entra ID token as '{UserName}'"
        : $"password login '{UserName}'";

    /// <param name="userNameKey">For example <c>SQL_USERNAME</c>.</param>
    /// <param name="passwordKey">For example <c>SQL_PASSWORD</c>.</param>
    /// <param name="tokenNeedsUserName">
    /// PostgreSQL takes the token as the password of a named role; SQL Server identifies the principal
    /// from the token alone.
    /// </param>
    public static DatabaseLogin Create(
        IConfiguration configuration,
        WorkloadIdentity identity,
        string userNameKey,
        string passwordKey,
        string scope,
        bool tokenNeedsUserName)
    {
        var userName = Value(configuration, userNameKey);
        var password = Value(configuration, passwordKey);

        if (password is not null)
        {
            return new DatabaseLogin(
                userName ?? throw new InvalidOperationException($"{passwordKey} is set but {userNameKey} is not."),
                password, credential: null, scope);
        }

        if (identity.Entra is not { } entra)
        {
            throw new InvalidOperationException(
                $"No database credential: set {passwordKey} (and {userNameKey}), or give the pod an Entra workload " +
                "identity (AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE).");
        }

        if (tokenNeedsUserName && userName is null)
        {
            throw new InvalidOperationException($"{userNameKey} is required to sign in with an Entra ID token.");
        }

        return new DatabaseLogin(tokenNeedsUserName ? userName : null, password: null, entra.Credential, scope);
    }

    private static string? Value(IConfiguration configuration, string key) =>
        string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key];
}
