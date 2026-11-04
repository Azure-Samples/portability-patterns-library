using System.Diagnostics;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;
using OrderManagement.Shared.Storage;
using Polly;

namespace OrderManagement.Processor;

/// <summary>
/// Consumes orders from the portable queue, reserves their stock with the inventory service,
/// archives each one as a JSON document in object storage, and records it in SQL as processed, or
/// rejected when the stock is not there. The document is written before the SQL row so the row
/// always points at an archive that exists; the reservation, the archive and the SQL insert are
/// idempotent per order, so a redelivered message is safe to reprocess. Transient failures are
/// retried in place (<see cref="ProcessorOptions"/>). When an order fails on its last delivery and is
/// not recorded, its stock is released before the broker dead-letters it.
/// </summary>
public sealed class OrderProcessor(
    IMessageQueue queue,
    IArchiveStore archiveStore,
    IOrderStore orderStore,
    IInventoryClient inventory,
    [FromKeyedServices(OrderProcessor.PipelineName)] ResiliencePipeline pipeline,
    IOptions<ProcessorOptions> options,
    OrderMetrics metrics,
    ILogger<OrderProcessor> logger) : BackgroundService
{
    public const string PipelineName = "order-processing";

    private long _processed;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await queue.RunAsync(HandleMessageAsync, stoppingToken).ConfigureAwait(false);
        logger.LogInformation("Processor stopping after processing {Total} orders", Interlocked.Read(ref _processed));
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
            await pipeline.ExecuteAsync(
                async token => await ProcessAsync(order, started, token).ConfigureAwait(false), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (message.IsLastDelivery && !cancellationToken.IsCancellationRequested)
        {
            // The broker dead-letters the order after this, so the stock it may hold is given back,
            // unless the order was recorded.
            await ReleaseUnrecordedStockAsync(order, ex).ConfigureAwait(false);
            throw;
        }
    }

    private async Task ProcessAsync(Order order, long started, CancellationToken cancellationToken)
    {
        var reservation = await inventory.ReserveAsync(new ReservationRequest
        {
            OrderId = order.OrderId,
            Lines = order.Lines.Select(line => new ReservationLine { Sku = line.Sku, Quantity = line.Quantity }).ToList()
        }, cancellationToken).ConfigureAwait(false);

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
        using var timeout = new CancellationTokenSource(options.Value.ReleaseTimeout);

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
}
