using OrderManagement.Shared.Resilience;
using Polly;
using Polly.Retry;

namespace OrderManagement.Processor;

/// <summary>
/// How the processor rides out a dependency that is briefly down, from the <c>Processor</c> section.
/// Transient failures (the inventory service, SQL, object storage) are retried in place, with
/// exponential backoff, for up to <see cref="RetryBudget"/>: the queue allows only a few deliveries
/// per message, and a restart or failover must not use them up.
/// </summary>
public sealed class ProcessorOptions
{
    public const string SectionName = "Processor";

    /// <summary>The longest one delivery is retried for before it fails and the broker redelivers it.</summary>
    public TimeSpan RetryBudget { get; set; } = TimeSpan.FromMinutes(5);

    public TimeSpan RetryDelay { get; set; } = TimeSpan.FromSeconds(1);

    public TimeSpan MaxRetryDelay { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>How long releasing a dead-lettered order's stock may take.</summary>
    public TimeSpan ReleaseTimeout { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>One delivery's work, retried as a whole while its failures are transient.</summary>
    public void ConfigurePipeline(ResiliencePipelineBuilder pipeline, ILogger logger) => pipeline
        .AddTimeout(RetryBudget)
        .AddRetry(new RetryStrategyOptions
        {
            ShouldHandle = new PredicateBuilder().Handle<Exception>(TransientFailures.IsTransient),
            BackoffType = DelayBackoffType.Exponential,
            UseJitter = true,
            Delay = RetryDelay,
            MaxDelay = MaxRetryDelay,
            MaxRetryAttempts = int.MaxValue,
            OnRetry = args =>
            {
                logger.LogWarning("Transient failure (attempt {Attempt}): {Reason}. Retrying in {Delay}",
                    args.AttemptNumber + 1, args.Outcome.Exception!.Message, args.RetryDelay);
                return ValueTask.CompletedTask;
            }
        });
}
