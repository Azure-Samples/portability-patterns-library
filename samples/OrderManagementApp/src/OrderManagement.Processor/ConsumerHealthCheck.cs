using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace OrderManagement.Processor;

/// <summary>Live while the order processor's consumer loop runs.</summary>
public sealed class ConsumerHealthCheck(OrderProcessor processor) : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult(processor.ExecuteTask is { IsCompleted: false }
            ? HealthCheckResult.Healthy()
            : HealthCheckResult.Unhealthy("The order consumer is not running."));
}
