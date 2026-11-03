using System.Diagnostics.Metrics;
using Microsoft.Extensions.Logging.Abstractions;
using OrderManagement.Processor;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Inventory;
using OrderManagement.Shared.Messaging;
using OrderManagement.Shared.Models;
using OrderManagement.Shared.Persistence;
using OrderManagement.Shared.Storage;

namespace OrderManagement.Tests;

/// <summary>
/// What the processor does with an order's stock when the order fails on its last delivery, just
/// before the broker dead-letters it: the stock goes back only when the order is known not to be
/// recorded.
/// </summary>
public sealed class OrderProcessorReleaseTests
{
    [Fact]
    public async Task Releases_stock_when_the_order_is_not_recorded()
    {
        var store = new FakeOrderStore { FailRecord = true };
        var inventory = new FakeInventory();

        var failure = await RunOneAsync(store, inventory, lastDelivery: true);

        Assert.NotNull(failure);
        Assert.Equal([TestOrder.OrderId], inventory.Released);
    }

    [Fact]
    public async Task Keeps_stock_when_the_order_was_recorded_before_the_failure()
    {
        // The SQL write committed but its reply was lost, so the processor saw a failure.
        var store = new FakeOrderStore { FailRecord = true, CommitBeforeFailing = true };
        var inventory = new FakeInventory();

        var failure = await RunOneAsync(store, inventory, lastDelivery: true);

        Assert.NotNull(failure);
        Assert.Empty(inventory.Released);
    }

    [Fact]
    public async Task Keeps_stock_when_the_order_store_cannot_be_checked()
    {
        var store = new FakeOrderStore { FailRecord = true, FailLookup = true };
        var inventory = new FakeInventory();

        var failure = await RunOneAsync(store, inventory, lastDelivery: true);

        Assert.NotNull(failure);
        Assert.Empty(inventory.Released);
    }

    [Fact]
    public async Task Keeps_stock_on_an_earlier_delivery_so_the_retry_can_finish()
    {
        var store = new FakeOrderStore { FailRecord = true };
        var inventory = new FakeInventory();

        var failure = await RunOneAsync(store, inventory, lastDelivery: false);

        Assert.NotNull(failure);
        Assert.Empty(inventory.Released);
        Assert.Equal(0, store.Lookups);
    }

    [Fact]
    public async Task Records_the_order_when_nothing_fails()
    {
        var store = new FakeOrderStore();
        var inventory = new FakeInventory();

        var failure = await RunOneAsync(store, inventory, lastDelivery: true);

        Assert.Null(failure);
        Assert.Equal(OrderStatus.Processed, store.Recorded[TestOrder.OrderId]);
        Assert.Empty(inventory.Released);
    }

    private static readonly Order TestOrder = new()
    {
        OrderId = Guid.NewGuid(),
        CustomerId = "customer-1",
        CustomerName = "Test Customer",
        PlacedAt = DateTimeOffset.UtcNow,
        Lines = [new OrderLine { Sku = "GEN-500", ProductName = "Generator", Quantity = 2, UnitPrice = 10m }]
    };

    // Runs the processor over one delivery of the test order and returns what the handler threw.
    private static async Task<Exception?> RunOneAsync(FakeOrderStore store, FakeInventory inventory, bool lastDelivery)
    {
        var subscriber = new OneMessageSubscriber(new QueueMessage("message-1", TestOrder.ToJson()) { IsLastDelivery = lastDelivery });
        using var meters = new TestMeterFactory();
        var processor = new OrderProcessor(
            subscriber, new FakeArchiveStore(), store, inventory, new OrderMetrics(meters), NullLogger<OrderProcessor>.Instance);

        await processor.StartAsync(CancellationToken.None);
        await processor.ExecuteTask!;
        return subscriber.HandlerFailure;
    }

    private sealed class OneMessageSubscriber(QueueMessage message) : IMessageSubscriber
    {
        public Exception? HandlerFailure { get; private set; }

        public async Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken)
        {
            try
            {
                await handler(message, cancellationToken);
            }
            catch (Exception ex)
            {
                HandlerFailure = ex;
            }
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class FakeOrderStore : IOrderStore
    {
        public bool FailRecord { get; init; }
        public bool CommitBeforeFailing { get; init; }
        public bool FailLookup { get; init; }
        public Dictionary<Guid, string> Recorded { get; } = [];
        public int Lookups { get; private set; }

        public Task RecordAsync(Order order, string archiveUri, string status, string? statusReason, CancellationToken cancellationToken)
        {
            if (!FailRecord || CommitBeforeFailing)
            {
                Recorded[order.OrderId] = status;
            }
            return FailRecord ? throw new TimeoutException("The reply from SQL was lost.") : Task.CompletedTask;
        }

        public Task<StoredOrder?> GetForCustomerAsync(Guid orderId, string customerId, CancellationToken cancellationToken)
        {
            Lookups++;
            if (FailLookup)
            {
                throw new TimeoutException("SQL is unreachable.");
            }
            return Task.FromResult(Recorded.TryGetValue(orderId, out var status)
                ? new StoredOrder
                {
                    OrderId = orderId,
                    CustomerName = TestOrder.CustomerName,
                    Lines = TestOrder.Lines,
                    Total = TestOrder.Total,
                    Currency = TestOrder.Currency,
                    PlacedAt = TestOrder.PlacedAt,
                    ProcessedAt = DateTimeOffset.UtcNow,
                    ArchiveUri = "archive",
                    Status = status
                }
                : null);
        }

        public Task<IReadOnlyList<StoredOrder>> ListForCustomerAsync(string customerId, int top, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
    }

    private sealed class FakeInventory : IInventoryClient
    {
        public List<Guid> Released { get; } = [];

        public Task<ReservationResult> ReserveAsync(ReservationRequest request, CancellationToken cancellationToken) =>
            Task.FromResult(new ReservationResult { OrderId = request.OrderId, Status = ReservationStatus.Reserved });

        public Task ReleaseAsync(Guid orderId, CancellationToken cancellationToken)
        {
            Released.Add(orderId);
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<Product>> GetProductsAsync(CancellationToken cancellationToken) => throw new NotSupportedException();

        public Task<Product?> RestockAsync(string sku, int quantity, CancellationToken cancellationToken) => throw new NotSupportedException();
    }

    private sealed class FakeArchiveStore : IArchiveStore
    {
        public Task InitializeAsync(CancellationToken cancellationToken) => Task.CompletedTask;

        public Task<string> ArchiveAsync(Order order, CancellationToken cancellationToken) => Task.FromResult($"archive/{order.OrderId}.json");
    }

    private sealed class TestMeterFactory : IMeterFactory
    {
        private readonly List<Meter> _meters = [];

        public Meter Create(MeterOptions options)
        {
            var meter = new Meter(options);
            _meters.Add(meter);
            return meter;
        }

        public void Dispose() => _meters.ForEach(meter => meter.Dispose());
    }
}
