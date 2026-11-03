using System.Diagnostics;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;
using OrderManagement.Shared.Storage;

namespace OrderManagement.Processor;

/// <summary>
/// Consumes orders from the portable queue, reserves their stock with the inventory service,
/// archives each one as a JSON blob in object storage, and records it in SQL Server as processed,
/// or rejected when the stock is not there. The blob is written before the SQL row so the row
/// always points at an archive that exists; the reservation and the SQL upsert are idempotent per
/// order, so a redelivered message is safe to reprocess. When an order fails on its last delivery
/// and is not recorded, its stock is released before the broker dead-letters it.
/// </summary>
public sealed class OrderProcessor(
    IMessageSubscriber subscriber,
    IArchiveStore archiveStore,
    IOrderStore orderStore,
    IInventoryClient inventory,
    OrderMetrics metrics,
    ILogger<OrderProcessor> logger) : BackgroundService
{
    // Long enough to ride out an inventory restart without using up the message's deliveries.
    private static readonly TimeSpan InventoryRetryBudget = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan MaxRetryDelay = TimeSpan.FromSeconds(30);

    private long _processed;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Processor starting; initializing object storage");

        await archiveStore.InitializeAsync(stoppingToken).ConfigureAwait(false);

        logger.LogInformation("Object storage ready; beginning to consume");

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

        var started = Stopwatch.GetTimestamp();
        var order = message.ToOrder();

        try
        {
            await ProcessAsync(order, started, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (message.IsLastDelivery)
        {
            // The broker dead-letters the order after this, so the stock it may hold is given back,
            // unless the order was recorded.
            await ReleaseUnrecordedStockAsync(order, ex).ConfigureAwait(false);
            throw;
        }
    }

    private async Task ProcessAsync(Order order, long started, CancellationToken cancellationToken)
    {
        var reservation = await ReserveAsync(order, cancellationToken).ConfigureAwait(false);
        var reserved = reservation.Status == ReservationStatus.Reserved;
        var (status, reason) = reserved
            ? (OrderStatus.Processed, (string?)null)
            : (OrderStatus.Rejected, OrderStatus.OutOfStockReason);

        var archiveUri = await archiveStore.ArchiveAsync(order, cancellationToken).ConfigureAwait(false);
        await orderStore.RecordAsync(order, archiveUri, status, reason, cancellationToken).ConfigureAwait(false);

        metrics.OrderCompleted(reserved ? "processed" : "rejected", Stopwatch.GetElapsedTime(started));
        var processed = Interlocked.Increment(ref _processed);

        if (reserved)
        {
            logger.LogInformation(
                "Processed order {OrderId} ({LineCount} lines, {Total} {Currency}) -> {ArchiveUri}; total {Processed}",
                order.OrderId, order.Lines.Count, order.Total, order.Currency, archiveUri, processed);
        }
        else
        {
            logger.LogWarning(
                "Rejected order {OrderId}: out of stock for {Skus} -> {ArchiveUri}; total {Processed}",
                order.OrderId, string.Join(", ", reservation.UnavailableSkus), archiveUri, processed);
        }
    }

    // Best effort, with its own timeout: the message is dead-lettered whether or not this works.
    // A failure can come after the order was recorded, for example when the SQL write committed but
    // its reply was lost, and a recorded order keeps its stock. So the stock is released only when
    // the order store says the order isn't there; when that can't be checked, it is kept and logged,
    // to be settled by hand, rather than sold twice.
    private async Task ReleaseUnrecordedStockAsync(Order order, Exception failure)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));

        StoredOrder? recorded;
        try
        {
            recorded = await orderStore.GetForCustomerAsync(order.OrderId, order.CustomerId, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            logger.LogError(failure,
                "Order {OrderId} failed on its last delivery and will be dead-lettered; its stock is kept because the order store could not be checked ({Reason}). Release it by hand if the order isn't recorded",
                order.OrderId, ExceptionSummary.Describe(ex));
            return;
        }

        if (recorded is not null)
        {
            logger.LogError(failure,
                "Order {OrderId} failed on its last delivery after it was recorded as {Status}; it will be dead-lettered and keeps its stock",
                order.OrderId, recorded.Status);
            return;
        }

        logger.LogError(failure, "Order {OrderId} failed on its last delivery and will be dead-lettered; releasing its stock",
            order.OrderId);
        try
        {
            await inventory.ReleaseAsync(order.OrderId, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is InventoryUnavailableException or InventoryRequestException or OperationCanceledException)
        {
            logger.LogError(ex, "Could not release the stock of dead-lettered order {OrderId}; release it by hand", order.OrderId);
        }
    }

    // A transient inventory failure is retried here, with backoff, rather than by redelivering the
    // message: the queue allows only a few deliveries. Past the budget the message fails and the
    // broker redelivers it later.
    private async Task<ReservationResult> ReserveAsync(Order order, CancellationToken cancellationToken)
    {
        var request = new ReservationRequest
        {
            OrderId = order.OrderId,
            Lines = order.Lines.Select(line => new ReservationLine { Sku = line.Sku, Quantity = line.Quantity }).ToList()
        };

        var deadline = DateTimeOffset.UtcNow + InventoryRetryBudget;
        var delay = TimeSpan.FromSeconds(1);
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                return await inventory.ReserveAsync(request, cancellationToken).ConfigureAwait(false);
            }
            catch (InventoryUnavailableException ex) when (DateTimeOffset.UtcNow + delay < deadline)
            {
                logger.LogWarning(
                    "Inventory unavailable for order {OrderId} (attempt {Attempt}): {Reason}. Retrying in {Delay}",
                    order.OrderId, attempt, ex.Message, delay);
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, MaxRetryDelay.TotalSeconds));
            }
        }
    }
}
