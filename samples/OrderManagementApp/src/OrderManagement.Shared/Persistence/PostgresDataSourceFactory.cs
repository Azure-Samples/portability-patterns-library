using Microsoft.Extensions.Logging;
using Npgsql;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Persistence;

/// <summary>Builds pooled PostgreSQL data sources for a <see cref="DatabaseLogin"/>.</summary>
public static class PostgresDataSourceFactory
{
    // Entra ID tokens last about an hour; asking every few minutes keeps new connections on a valid
    // one. Azure.Identity serves the cached token until it nears expiry, so this costs nothing.
    private static readonly TimeSpan TokenRefreshInterval = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan TokenRetryInterval = TimeSpan.FromSeconds(10);

    public static NpgsqlDataSource Create(
        PostgresOptions options, DatabaseLogin login, ILoggerFactory loggerFactory, string? database = null)
    {
        var connectionString = options.CreateConnectionStringBuilder(database);
        connectionString.Username = login.UserName ?? throw new InvalidOperationException(
            "PostgreSQL needs a user name for every login, including Entra ID tokens.");

        if (!login.UsesToken)
        {
            connectionString.Password = login.Password;
        }

        var builder = new NpgsqlDataSourceBuilder(connectionString.ConnectionString);
        builder.UseLoggerFactory(loggerFactory);
        if (login.UsesToken)
        {
            builder.UsePeriodicPasswordProvider(
                async (_, cancellationToken) => (await login.GetTokenAsync(cancellationToken).ConfigureAwait(false)).Token,
                TokenRefreshInterval,
                TokenRetryInterval);
        }

        return builder.Build();
    }
}
