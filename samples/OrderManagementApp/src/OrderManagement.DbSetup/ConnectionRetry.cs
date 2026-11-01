using Microsoft.Extensions.Logging;
using OrderManagement.Shared.Diagnostics;

namespace OrderManagement.DbSetup;

/// <summary>
/// Retries opening the first connection to a server for up to five minutes: the job usually starts
/// alongside the database server (or while Azure SQL resumes) and must wait for it rather than fail.
/// </summary>
public static class ConnectionRetry
{
    public static readonly TimeSpan Budget = TimeSpan.FromMinutes(5);

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
            catch (Exception ex) when (DateTimeOffset.UtcNow < deadline && !cancellationToken.IsCancellationRequested)
            {
                var delay = TimeSpan.FromSeconds(Math.Min(10, attempt * 2));
                logger.LogWarning("{Target} not reachable yet (attempt {Attempt}): {Reason}. Retrying in {Delay}",
                    target, attempt, ExceptionSummary.Describe(ex), delay);
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
        }
    }
}
