using Microsoft.Extensions.Logging;
using Npgsql;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Persistence;

/// <summary>Builds pooled PostgreSQL data sources whose password comes from a credential provider.</summary>
public static class PostgresDataSourceFactory
{
    // Entra ID tokens last about an hour; asking every few minutes keeps new connections on a valid
    // one. Azure.Identity serves the cached token until it nears expiry, so this costs nothing.
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(10);

    public static NpgsqlDataSource Create(
        PostgresOptions options,
        IDatabaseCredentialProvider credentials,
        ILoggerFactory loggerFactory,
        string? database = null)
    {
        var userName = credentials.UserName ?? throw new InvalidOperationException(
            "PostgreSQL needs a user name for every credential, including Entra ID tokens.");

        var builder = new NpgsqlDataSourceBuilder(options.BuildConnectionString(userName, database));
        builder.UseLoggerFactory(loggerFactory);
        builder.UsePeriodicPasswordProvider(
            async (_, cancellationToken) =>
                (await credentials.GetCredentialAsync(cancellationToken).ConfigureAwait(false)).Secret,
            RefreshInterval,
            RetryInterval);

        return builder.Build();
    }
}
