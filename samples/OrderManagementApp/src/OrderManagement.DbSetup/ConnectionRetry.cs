using System.Data.Common;
using System.Net.Sockets;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using OrderManagement.Shared.Diagnostics;

namespace OrderManagement.DbSetup;

/// <summary>
/// Retries opening the first connection to a server for up to five minutes: the job can start while
/// the database server is still starting, or while Azure SQL resumes. Only errors that go away on
/// their own are retried; a wrong password or a missing permission fails at once.
/// </summary>
public static class ConnectionRetry
{
    public static readonly TimeSpan Budget = TimeSpan.FromMinutes(5);

    // SQL Server errors that mean "not ready yet": the database is starting, recovering, resuming or
    // being moved, or the server is in upgrade mode after a restart.
    private static readonly HashSet<int> TransientSqlErrors = [-2, 20, 53, 64, 121, 233, 4060, 4221, 10053, 10054, 10060, 10928, 10929, 18401, 40143, 40197, 40501, 40613, 42108, 42109];

    public static async Task<T> OpenAsync<T>(
        Func<CancellationToken, Task<T>> open, string target, ILogger logger, CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + Budget;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await open(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (IsTransient(ex) && DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(10, attempt * 2));
                logger.LogWarning("{Target} not reachable yet (attempt {Attempt}): {Reason}. Retrying in {Delay}",
                    target, attempt, ExceptionSummary.Describe(ex), delay);
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
        }
    }

    public static bool IsTransient(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            switch (current)
            {
                case SqlException sql when sql.Errors.Cast<SqlError>().Any(error => TransientSqlErrors.Contains(error.Number)):
                case DbException { IsTransient: true }:
                case SocketException:
                case TimeoutException:
                    return true;
            }
        }

        return false;
    }
}
