using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;
using OrderManagement.Shared.Storage;

namespace OrderManagement.Processor;

/// <summary>
/// Consumes orders from the portable queue, archives each one as a JSON blob in object storage, and
/// records it in SQL Server. The blob is written before the SQL row so the row always points at an
/// archive that exists; the SQL upsert is idempotent so a redelivered message is safe to reprocess.
/// </summary>
public sealed class OrderProcessor(
    IMessageSubscriber subscriber,
    IArchiveStore archiveStore,
    IOrderStore orderStore,
    ILogger<OrderProcessor> logger) : BackgroundService
{
    private long _processed;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Processor starting; initializing backing stores");

        await archiveStore.InitializeAsync(stoppingToken).ConfigureAwait(false);
        await orderStore.InitializeAsync(stoppingToken).ConfigureAwait(false);

        logger.LogInformation("Backing stores ready; beginning to consume");

        await subscriber.RunAsync(HandleMessageAsync, stoppingToken).ConfigureAwait(false);

        logger.LogInformation("Processor stopping after processing {Total} orders", _processed);
    }

    private async Task HandleMessageAsync(QueueMessage message, CancellationToken cancellationToken)
    {
        if (!message.IsOrder)
        {
            // Acknowledged rather than retried: redelivering a message that is not an order can never succeed.
            logger.LogWarning("Skipping message {MessageId}: it is not an order", message.MessageId);
            return;
        }

        var order = message.ToOrder();
        var archiveUri = await archiveStore.ArchiveAsync(order, cancellationToken).ConfigureAwait(false);
        await orderStore.RecordAsync(order, archiveUri, cancellationToken).ConfigureAwait(false);

        var processed = Interlocked.Increment(ref _processed);

        logger.LogInformation(
            "Processed order {OrderId} ({LineCount} lines, {Total} {Currency}) -> {ArchiveUri}; total {Processed}",
            order.OrderId, order.Lines.Count, order.Total, order.Currency, archiveUri, processed);
    }
}
