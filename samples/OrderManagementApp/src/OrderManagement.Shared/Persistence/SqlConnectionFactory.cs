using Microsoft.Data.SqlClient;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Persistence;

/// <summary>
/// Opens connections to Azure SQL Database (Entra ID access token from the workload identity) or to
/// a SQL Server container (SQL login). Shared by every SQL-backed store. The schema belongs to
/// dbsetup; the principals this opens connections as can only read and write rows.
/// </summary>
public sealed class SqlConnectionFactory
{
    public const string CredentialKey = "sql";

    private readonly SqlOptions _options;
    private readonly IDatabaseCredentialProvider _credentials;

    public SqlConnectionFactory(
        SqlOptions options,
        [FromKeyedServices(CredentialKey)] IDatabaseCredentialProvider credentials,
        ILogger<SqlConnectionFactory> logger)
    {
        _options = options;
        _credentials = credentials;

        logger.LogInformation("Connecting to SQL host {Host}, database {Database}, with {Credential}",
            options.Host, options.Database, credentials.Description);
    }

    public Task<SqlConnection> OpenAsync(CancellationToken cancellationToken) => OpenAsync(null, cancellationToken);

    /// <param name="database">Another database on the same server, such as <c>master</c>; null for the application database.</param>
    public async Task<SqlConnection> OpenAsync(string? database, CancellationToken cancellationToken)
    {
        // Asked per connection so a rotated password or a renewed token is picked up without a restart.
        var credential = await _credentials.GetCredentialAsync(cancellationToken).ConfigureAwait(false);
        var connection = new SqlConnection(_options.BuildConnectionString(credential, database));

        if (credential.IsAccessToken)
        {
            connection.AccessToken = credential.Secret;
        }

        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }
}
