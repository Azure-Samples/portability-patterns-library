using OrderManagement.Shared.Resilience;
using Polly;
using Polly.Retry;

namespace OrderManagement.Processor;

/// <summary>
/// How the processor rides out a dependency that is briefly down, from the <c>Processor</c> section.
/// Transient failures (the inventory service, SQL, object storage) are retried in place a few times,
/// with exponential backoff and jitter, about a minute in all; past that the delivery fails and the
/// broker redelivers the message, up to the queue's delivery limit.
/// </summary>
public sealed class ProcessorOptions
{
    public const string SectionName = "Processor";

    public int MaxRetryAttempts { get; set; } = 5;

    public TimeSpan RetryDelay { get; set; } = TimeSpan.FromSeconds(2);

    public TimeSpan MaxRetryDelay { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>How long releasing a dead-lettered order's stock may take.</summary>
    public TimeSpan ReleaseTimeout { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>One delivery's work, retried as a whole while its failures are transient.</summary>
    public void ConfigurePipeline(ResiliencePipelineBuilder pipeline, ILogger logger) => pipeline
        .AddRetry(new RetryStrategyOptions
        {
            ShouldHandle = new PredicateBuilder().Handle<Exception>(TransientFailures.IsTransient),
            BackoffType = DelayBackoffType.Exponential,
            UseJitter = true,
            Delay = RetryDelay,
            MaxDelay = MaxRetryDelay,
            MaxRetryAttempts = MaxRetryAttempts,
            OnRetry = args =>
            {
                logger.LogWarning("Transient failure (attempt {Attempt} of {MaxAttempts}): {Reason}. Retrying in {Delay}",
                    args.AttemptNumber + 1, MaxRetryAttempts + 1, args.Outcome.Exception!.Message, args.RetryDelay);
                return ValueTask.CompletedTask;
            }
        });
}
