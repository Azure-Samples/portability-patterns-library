using Bcd.Shared.Messaging;
using Bcd.Shared.Models;
using Bcd.Shared.Persistence;
using Bcd.Shared.Storage;

namespace Bcd.Consumer;

/// <summary>
/// Consumes orders and business continuity events from the portable queue, archives each one as a
/// JSON blob in object storage, and records a row in SQL Server. Blob write happens before the SQL
/// insert so the row always points at an archive that exists; the SQL upsert is idempotent so a
/// redelivered message is safe to reprocess.
/// </summary>
public sealed class ConsumerWorker(
    IMessageSubscriber subscriber,
    IArchiveStore archiveStore,
    IEventRecordStore recordStore,
    IOrderStore orderStore,
    ILogger<ConsumerWorker> logger) : BackgroundService
{
    private long _processed;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Consumer starting; initializing backing stores");

        await archiveStore.InitializeAsync(stoppingToken).ConfigureAwait(false);
        await recordStore.InitializeAsync(stoppingToken).ConfigureAwait(false);
        await orderStore.InitializeAsync(stoppingToken).ConfigureAwait(false);

        logger.LogInformation("Backing stores ready; beginning to consume");

        await subscriber.RunAsync(HandleMessageAsync, stoppingToken).ConfigureAwait(false);

        logger.LogInformation("Consumer stopping after processing {Total} messages", _processed);
    }

    private async Task HandleMessageAsync(QueueMessage message, CancellationToken cancellationToken)
    {
        if (message.IsOrder)
        {
            await HandleOrderAsync(message.ToOrder(), cancellationToken).ConfigureAwait(false);
            return;
        }

        var businessEvent = message.ToBusinessEvent();

        var archiveUri = await archiveStore.ArchiveAsync(businessEvent, cancellationToken).ConfigureAwait(false);
        await recordStore.RecordAsync(businessEvent, archiveUri, cancellationToken).ConfigureAwait(false);

        var processed = Interlocked.Increment(ref _processed);

        logger.LogInformation(
            "Processed {EventType} event {EventId} -> {ArchiveUri}; total {Total}",
            businessEvent.EventType, businessEvent.EventId, archiveUri, processed);
    }

    private async Task HandleOrderAsync(Order order, CancellationToken cancellationToken)
    {
        var archiveUri = await archiveStore.ArchiveAsync(order, cancellationToken).ConfigureAwait(false);
        await orderStore.RecordAsync(order, archiveUri, cancellationToken).ConfigureAwait(false);

        var processed = Interlocked.Increment(ref _processed);

        logger.LogInformation(
            "Processed order {OrderId} ({LineCount} lines, {Total} {Currency}) -> {ArchiveUri}; total {Processed}",
            order.OrderId, order.Lines.Count, order.Total, order.Currency, archiveUri, processed);
    }
}
