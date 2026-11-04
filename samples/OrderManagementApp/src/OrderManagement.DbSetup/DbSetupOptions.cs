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
    /// Retries opening the first connection while the failure is transient, with backoff. A wrong
    /// password or a missing permission fails at once.
    /// </summary>
    public ResiliencePipeline CreateConnectPipeline(string target, ILogger logger) =>
        new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                ShouldHandle = new PredicateBuilder().Handle<Exception>(TransientFailures.IsTransient),
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
