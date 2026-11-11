using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Resilience;
using Polly;
using Polly.Retry;

namespace OrderManagement.DbSetup;

/// <summary>From the <c>DbSetup</c> section.</summary>
public sealed class DbSetupOptions
{
    public const string SectionName = "DbSetup";

    /// <summary>
    /// How often opening the first connection is retried: the job can start while the database
    /// server is still starting, or while Azure SQL resumes. About a minute and a half in all.
    /// </summary>
    public int ConnectRetries { get; set; } = 10;

    /// <summary>
    /// Retries opening the first connection while the failure is transient, with backoff. Other
    /// failures, such as a wrong password or a missing permission, fail at once. A SQL Server that is
    /// still starting can accept a connection and then end the login without saying why: SqlClient
    /// reports that as error 0 ("A severe error occurred"), which it doesn't count as transient, so it
    /// is retried here too.
    /// </summary>
    /// <param name="retryLoginFailure">
    /// Also retry a login failure (18456): for an Entra token login to Azure SQL, whose newly set
    /// Entra administrator can take a moment to take effect. Never for a password login.
    /// </param>
    public ResiliencePipeline CreateConnectPipeline(string target, ILogger logger, bool retryLoginFailure = false) =>
        new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                ShouldHandle = new PredicateBuilder().Handle<Exception>(exception =>
                    TransientFailures.IsTransient(exception)
                    || exception is SqlException { Number: 0 }
                    || (retryLoginFailure && exception is SqlException { Number: 18456 })),
                BackoffType = DelayBackoffType.Exponential,
                Delay = TimeSpan.FromSeconds(2),
                MaxDelay = TimeSpan.FromSeconds(10),
                MaxRetryAttempts = ConnectRetries,
                OnRetry = args =>
                {
                    logger.LogWarning("{Target} not reachable yet (attempt {Attempt} of {MaxAttempts}): {Reason}. Retrying in {Delay}",
                        target, args.AttemptNumber + 1, ConnectRetries + 1, ExceptionSummary.Describe(args.Outcome.Exception!), args.RetryDelay);
                    return ValueTask.CompletedTask;
                }
            })
            .Build();
}
