using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace OrderManagement.Shared.Persistence;

/// <summary>Ready when the service can open a connection to its SQL database and run a query.</summary>
public sealed class SqlHealthCheck(SqlConnectionFactory connections) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var connection = await connections.OpenAsync(cancellationToken).ConfigureAwait(false);
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT 1";
            await command.ExecuteScalarAsync(cancellationToken).ConfigureAwait(false);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Unhealthy("Cannot query the SQL database.", ex);
        }
    }
}
