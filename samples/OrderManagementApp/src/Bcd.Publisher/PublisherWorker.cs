using Bcd.Shared.Messaging;
using Bcd.Shared.Models;

namespace Bcd.Publisher;

/// <summary>
/// Generates a random business continuity event on a fixed interval and publishes it as JSON to the
/// portable queue. Knows nothing about RabbitMQ or Azure Service Bus.
/// </summary>
public sealed class PublisherWorker(
    IMessagePublisher publisher,
    IConfiguration configuration,
    ILogger<PublisherWorker> logger) : BackgroundService
{
    private readonly TimeSpan _interval = TimeSpan.FromSeconds(
        configuration.GetValue("Bcd:Publisher:IntervalSeconds", 5));

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (_interval <= TimeSpan.Zero)
        {
            logger.LogInformation("Scheduled event generation is off; events are published through the API");
            return;
        }

        logger.LogInformation("Publisher starting; interval {Interval}", _interval);

        var published = 0L;
        using var timer = new PeriodicTimer(_interval);

        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false))
        {
            var businessEvent = BusinessEventGenerator.Create();

            try
            {
                await publisher.PublishAsync(businessEvent, stoppingToken).ConfigureAwait(false);
                published++;

                logger.LogInformation(
                    "Published {EventType} event {EventId} (severity {Severity}, region {Region}); total {Total}",
                    businessEvent.EventType, businessEvent.EventId, businessEvent.Severity,
                    businessEvent.Region, published);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                // Keep the worker alive; the next tick retries. The broker client handles reconnects.
                logger.LogError(ex, "Failed to publish event {EventId}", businessEvent.EventId);
            }
        }

        logger.LogInformation("Publisher stopping after publishing {Total} events", published);
    }
}
