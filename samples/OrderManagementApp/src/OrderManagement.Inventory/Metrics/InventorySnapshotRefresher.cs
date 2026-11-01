using OrderManagement.Inventory.Data;
using OrderManagement.Shared.Diagnostics;

namespace OrderManagement.Inventory.Metrics;

/// <summary>Reads stock levels into <see cref="InventorySnapshot"/> once a minute.</summary>
public sealed class InventorySnapshotRefresher(
    IProductRepository products,
    InventorySnapshot snapshot,
    ILogger<InventorySnapshotRefresher> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(60);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Interval);
        do
        {
            try
            {
                snapshot.Update(await products.ListAsync(stoppingToken).ConfigureAwait(false));
            }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested)
            {
                // The gauges keep their last values; the next tick tries again.
                logger.LogWarning("Could not read stock levels for metrics: {Reason}", ExceptionSummary.Describe(ex));
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false));
    }
}
