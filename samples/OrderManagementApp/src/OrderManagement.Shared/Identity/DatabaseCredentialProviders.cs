using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Identity;

/// <summary>
/// Chooses how a service authenticates to its database from what the platform provides: a password
/// when one is set, otherwise the pod's Entra workload identity. Connection targets (host, port,
/// database) come from the <c>CONNECTION_*</c> values; credentials never do.
/// </summary>
public static class DatabaseCredentialProviders
{
    public const string SqlScope = "https://database.windows.net/.default";
    public const string PostgresScope = "https://ossrdbms-aad.database.windows.net/.default";

    public const string DefaultPostgresUserName = "inventory";

    /// <summary>The api and the processor: <c>SQL_USERNAME</c>, <c>SQL_PASSWORD</c>.</summary>
    public static IDatabaseCredentialProvider ForSql(IConfiguration configuration) =>
        Create(configuration, "SQL_USERNAME", "SQL_PASSWORD", SqlScope, defaultUserName: null, tokenNeedsUserName: false);

    /// <summary>The inventory service: <c>POSTGRES_USERNAME</c> (default <c>inventory</c>), <c>POSTGRES_PASSWORD</c>.</summary>
    public static IDatabaseCredentialProvider ForPostgres(IConfiguration configuration) =>
        Create(configuration, "POSTGRES_USERNAME", "POSTGRES_PASSWORD", PostgresScope, DefaultPostgresUserName, tokenNeedsUserName: true);

    /// <param name="tokenNeedsUserName">
    /// PostgreSQL takes the token as the password of a named role; SQL Server identifies the
    /// principal from the token alone.
    /// </param>
    public static IDatabaseCredentialProvider Create(
        IConfiguration configuration,
        string userNameKey,
        string passwordKey,
        string scope,
        string? defaultUserName,
        bool tokenNeedsUserName)
    {
        var userName = Value(configuration, userNameKey) ?? defaultUserName;
        var password = Value(configuration, passwordKey);

        if (password is not null)
        {
            return new PasswordCredentialProvider(
                userName ?? throw new InvalidOperationException($"{passwordKey} is set but {userNameKey} is not."),
                password);
        }

        if (AzureCredentialFactory.HasWorkloadIdentity)
        {
            if (tokenNeedsUserName && userName is null)
            {
                throw new InvalidOperationException($"{userNameKey} is required to sign in with an Entra ID token.");
            }

            return new EntraTokenCredentialProvider(AzureCredentialFactory.Create(), scope, tokenNeedsUserName ? userName : null);
        }

        throw new InvalidOperationException(
            $"No database credential: set {passwordKey} (and {userNameKey}), or give the pod an Entra workload " +
            "identity (AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE).");
    }

    private static string? Value(IConfiguration configuration, string key) =>
        string.IsNullOrWhiteSpace(configuration[key]) ? null : configuration[key];
}
