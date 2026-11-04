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
    /// How long the job waits for a server to accept the first connection: it can start while the
    /// database server is still starting, or while Azure SQL resumes.
    /// </summary>
    public TimeSpan ConnectBudget { get; set; } = TimeSpan.FromMinutes(5);

    /// <summary>How long a run waits for another run (another deployment, say) to finish first.</summary>
    public TimeSpan LockTimeout { get; set; } = TimeSpan.FromMinutes(10);

    /// <summary>
    /// Retries opening the first connection while the failure is transient, with backoff, for up to
    /// <see cref="ConnectBudget"/>. A wrong password or a missing permission fails at once.
    /// </summary>
    public ResiliencePipeline CreateConnectPipeline(string target, ILogger logger) =>
        new ResiliencePipelineBuilder()
            .AddTimeout(ConnectBudget)
            .AddRetry(new RetryStrategyOptions
            {
                ShouldHandle = new PredicateBuilder().Handle<Exception>(TransientFailures.IsTransient),
                BackoffType = DelayBackoffType.Exponential,
                Delay = TimeSpan.FromSeconds(2),
                MaxDelay = TimeSpan.FromSeconds(10),
                MaxRetryAttempts = int.MaxValue,
                OnRetry = args =>
                {
                    logger.LogWarning("{Target} not reachable yet (attempt {Attempt}): {Reason}. Retrying in {Delay}",
                        target, args.AttemptNumber + 1, ExceptionSummary.Describe(args.Outcome.Exception!), args.RetryDelay);
                    return ValueTask.CompletedTask;
                }
            })
            .Build();
}
