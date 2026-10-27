using Azure.Core;
using OrderManagement.Shared.Configuration;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Identity;
using Dapper;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;

namespace OrderManagement.Shared.Persistence;

/// <summary>
/// Opens connections to Azure SQL Database (Entra ID access token obtained through Workload Identity)
/// or to a containerized SQL Server (SQL login). Shared by every SQL-backed store.
/// </summary>
public sealed class SqlConnectionFactory
{
    private readonly SqlOptions _options;
    private readonly ILogger<SqlConnectionFactory> _logger;
    private readonly TokenCredential? _credential;

    public SqlConnectionFactory(SqlOptions options, ILogger<SqlConnectionFactory> logger)
    {
        _options = options;
        _logger = logger;

        if (options.UseEntraId)
        {
            _logger.LogInformation(
                "Using Entra ID authentication for SQL host {Host} through workload identity",
                options.Host);
            _credential = AzureCredentialFactory.Create();
        }
        else
        {
            _logger.LogInformation("Using SQL authentication for SQL host {Host}", options.Host);
        }
    }

    // Built per connection rather than once, so a password rotated by a vault or secret store is
    // picked up without restarting the worker. The token path already re-reads for the same reason.
    public Task<SqlConnection> OpenAsync(CancellationToken cancellationToken) =>
        OpenAsync(_options.BuildConnectionString(), cancellationToken);

    private async Task<SqlConnection> OpenAsync(string connectionString, CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(connectionString);

        if (_credential is not null)
        {
            var token = await _credential.GetTokenAsync(
                new TokenRequestContext([SqlOptions.EntraScope]),
                cancellationToken).ConfigureAwait(false);

            connection.AccessToken = token.Token;
        }

        await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
        return connection;
    }

    /// <summary>
    /// Creates the application database when missing, then runs an idempotent schema script.
    /// Retries because on a cold environment the SQL container may still be starting.
    /// </summary>
    public async Task EnsureSchemaAsync(string schemaSql, string description, CancellationToken cancellationToken)
    {
        const int maxAttempts = 30;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await EnsureDatabaseExistsAsync(cancellationToken).ConfigureAwait(false);

                await using var connection = await OpenAsync(cancellationToken).ConfigureAwait(false);
                await connection.ExecuteAsync(new CommandDefinition(schemaSql, cancellationToken: cancellationToken))
                    .ConfigureAwait(false);

                _logger.LogInformation("SQL schema for {Description} ready on database {Database}",
                    description, _options.Database);
                return;
            }
            catch (Exception ex) when (attempt < maxAttempts && !cancellationToken.IsCancellationRequested)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(10, attempt * 2));

                // Summarised at warning; the full exception is available at debug level.
                _logger.LogWarning(
                    "SQL not ready for {Description} (attempt {Attempt}/{MaxAttempts}): {Reason}. Retrying in {Delay}",
                    description, attempt, maxAttempts, ExceptionSummary.Describe(ex), delay);
                _logger.LogDebug(ex, "SQL initialization attempt {Attempt} failed", attempt);

                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    /// <summary>
    /// Creates the application database when it does not exist. Required for the local SQL Server
    /// container, which starts with only the system databases. On Azure SQL the database is created
    /// by the Recipe and the principal usually cannot create databases, so failures are tolerated.
    /// </summary>
    private async Task EnsureDatabaseExistsAsync(CancellationToken cancellationToken)
    {
        try
        {
            await using var connection = await OpenAsync(
                _options.BuildMasterConnectionString(), cancellationToken).ConfigureAwait(false);

            // The database name cannot be parameterized in CREATE DATABASE, so it is quoted instead.
            var quoted = _options.Database.Replace("]", "]]", StringComparison.Ordinal);
            var sql = $"IF DB_ID(@database) IS NULL CREATE DATABASE [{quoted}];";

            await connection.ExecuteAsync(new CommandDefinition(
                sql, new { database = _options.Database }, cancellationToken: cancellationToken))
                .ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "Could not ensure database {Database} exists; assuming it is managed externally",
                _options.Database);
        }
    }
}
