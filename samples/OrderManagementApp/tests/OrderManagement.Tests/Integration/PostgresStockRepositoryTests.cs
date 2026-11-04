using Npgsql;
using OrderManagement.Inventory.Data;
using OrderManagement.Shared.Models;

namespace OrderManagement.Tests.Integration;

/// <summary>
/// Stock reservations against a real PostgreSQL, signed in as the inventory service's role: a
/// redelivered order reserves once, released stock comes back once, and stock never goes negative,
/// however many orders arrive at once.
/// </summary>
[Collection(PostgresCollection.Name)]
public sealed class PostgresStockRepositoryTests(PostgresFixture database)
{
    private readonly PostgresStockRepository _stock = new(database.Inventory);

    [SkippableFact]
    public async Task Reserves_once_for_a_redelivered_order()
    {
        SkipWithoutContainers();
        var sku = await NewProductAsync(available: 10);
        var order = Guid.NewGuid();

        var first = await ReserveAsync(order, (sku, 3));
        var again = await ReserveAsync(order, (sku, 3));

        Assert.Equal(ReservationStatus.Reserved, first.Status);
        Assert.Equal(ReservationStatus.Reserved, again.Status);
        Assert.Equal(7, await AvailableAsync(sku));
    }

    [SkippableFact]
    public async Task Gives_released_stock_back_once()
    {
        SkipWithoutContainers();
        var sku = await NewProductAsync(available: 10);
        var order = Guid.NewGuid();
        await ReserveAsync(order, (sku, 4));

        Assert.True(await _stock.ReleaseAsync(order, CancellationToken.None));
        Assert.False(await _stock.ReleaseAsync(order, CancellationToken.None));
        Assert.False(await _stock.ReleaseAsync(Guid.NewGuid(), CancellationToken.None));
        Assert.Equal(10, await AvailableAsync(sku));
    }

    [SkippableFact]
    public async Task Reserves_a_released_order_again_when_it_is_replayed()
    {
        SkipWithoutContainers();
        var sku = await NewProductAsync(available: 10);
        var order = Guid.NewGuid();
        await ReserveAsync(order, (sku, 4));
        await _stock.ReleaseAsync(order, CancellationToken.None);

        var replayed = await ReserveAsync(order, (sku, 4));

        Assert.Equal(ReservationStatus.Reserved, replayed.Status);
        Assert.Equal(6, await AvailableAsync(sku));
    }

    [SkippableFact]
    public async Task Reserves_every_line_or_none()
    {
        SkipWithoutContainers();
        var plenty = await NewProductAsync(available: 10);
        var scarce = await NewProductAsync(available: 1);
        var order = Guid.NewGuid();

        var result = await ReserveAsync(order, (plenty, 2), (scarce, 2));
        var again = await ReserveAsync(order, (plenty, 2), (scarce, 2));

        Assert.Equal(ReservationStatus.OutOfStock, result.Status);
        Assert.Equal([scarce], result.UnavailableSkus);
        Assert.Equal(ReservationStatus.OutOfStock, again.Status);
        Assert.Equal(10, await AvailableAsync(plenty));
        Assert.Equal(1, await AvailableAsync(scarce));
        Assert.False(await _stock.ReleaseAsync(order, CancellationToken.None));
    }

    [SkippableFact]
    public async Task Records_nothing_for_unknown_products()
    {
        SkipWithoutContainers();
        var outcome = await _stock.ReserveAsync(Guid.NewGuid(), [new ReservationLine { Sku = "NO-SUCH-SKU", Quantity = 1 }], CancellationToken.None);

        Assert.Null(outcome.Result);
        Assert.Equal(["NO-SUCH-SKU"], outcome.UnknownSkus);
    }

    [SkippableFact]
    public async Task Never_sells_more_than_is_in_stock_when_orders_arrive_at_once()
    {
        SkipWithoutContainers();
        var sku = await NewProductAsync(available: 10);

        var results = await Task.WhenAll(Enumerable.Range(0, 25).Select(_ => ReserveAsync(Guid.NewGuid(), (sku, 1))));

        Assert.Equal(10, results.Count(result => result.Status == ReservationStatus.Reserved));
        Assert.Equal(15, results.Count(result => result.Status == ReservationStatus.OutOfStock));
        Assert.Equal(0, await AvailableAsync(sku));
    }

    [SkippableFact]
    public async Task Reserves_once_when_one_order_is_delivered_several_times_at_once()
    {
        SkipWithoutContainers();
        var sku = await NewProductAsync(available: 10);
        var order = Guid.NewGuid();

        var results = await Task.WhenAll(Enumerable.Range(0, 10).Select(_ => ReserveAsync(order, (sku, 2))));

        Assert.All(results, result => Assert.Equal(ReservationStatus.Reserved, result.Status));
        Assert.Equal(8, await AvailableAsync(sku));
    }

    [SkippableFact]
    public async Task Keeps_count_when_reservations_and_releases_of_overlapping_products_run_at_once()
    {
        SkipWithoutContainers();
        var first = await NewProductAsync(available: 100);
        var second = await NewProductAsync(available: 100);
        var placed = Enumerable.Range(0, 20).Select(_ => Guid.NewGuid()).ToList();
        await Task.WhenAll(placed.Select((order, i) => i % 2 == 0
            ? ReserveAsync(order, (first, 1), (second, 1))
            : ReserveAsync(order, (second, 1), (first, 1))));

        // Half are released while as many new orders reserve, in opposite product orders.
        await Task.WhenAll(
            placed.Take(10).Select(order => (Task)_stock.ReleaseAsync(order, CancellationToken.None))
                .Concat(Enumerable.Range(0, 10).Select(i => (Task)(i % 2 == 0
                    ? ReserveAsync(Guid.NewGuid(), (first, 1), (second, 1))
                    : ReserveAsync(Guid.NewGuid(), (second, 1), (first, 1))))));

        Assert.Equal(80, await AvailableAsync(first));
        Assert.Equal(80, await AvailableAsync(second));
    }

    private void SkipWithoutContainers() => Skip.If(database.Unavailable is not null, database.Unavailable);

    private async Task<ReservationResult> ReserveAsync(Guid order, params (string Sku, int Quantity)[] lines)
    {
        var outcome = await _stock.ReserveAsync(order,
            lines.Select(line => new ReservationLine { Sku = line.Sku, Quantity = line.Quantity }).ToList(), CancellationToken.None);
        return outcome.Result ?? throw new InvalidOperationException($"Unknown products: {string.Join(", ", outcome.UnknownSkus)}");
    }

    // Each test has products of its own, so tests don't see each other's stock.
    private async Task<string> NewProductAsync(int available)
    {
        var sku = $"T-{Guid.NewGuid():N}"[..14];
        await using var command = database.Admin.CreateCommand(
            "INSERT INTO inventory.products (sku, name, unit_price, currency, available, reorder_level) VALUES (@sku, 'Test product', 1, 'USD', @available, 0)");
        command.Parameters.AddWithValue("sku", sku);
        command.Parameters.AddWithValue("available", available);
        await command.ExecuteNonQueryAsync();
        return sku;
    }

    private async Task<int> AvailableAsync(string sku)
    {
        await using var command = database.Admin.CreateCommand("SELECT available FROM inventory.products WHERE sku = @sku");
        command.Parameters.AddWithValue("sku", sku);
        return (int)(await command.ExecuteScalarAsync())!;
    }
}
