using System.Diagnostics.Metrics;
using OrderManagement.Shared.Diagnostics;
using OrderManagement.Shared.Models;

namespace OrderManagement.Inventory.Metrics;

/// <summary>
/// Stock levels as last read by <see cref="InventorySnapshotRefresher"/>, published as gauges on the
/// <c>OrderManagement</c> meter. Exporters read the gauges from memory, so a scrape never queries
/// the database.
/// </summary>
public sealed class InventorySnapshot
{
    private volatile IReadOnlyList<Product>? _products;

    public InventorySnapshot(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create(OrderManagementTelemetry.Name);

        meter.CreateObservableGauge("oms.inventory.available", ObserveAvailable, "{unit}",
            "Units in stock and not reserved, by SKU.");
        meter.CreateObservableGauge("oms.inventory.below_reorder", ObserveBelowReorder, "{sku}",
            "Number of SKUs at or below their reorder level.");
    }

    public void Update(IReadOnlyList<Product> products) => _products = products;

    // Nothing is reported until the first read, rather than zeros that look like empty shelves.
    private IEnumerable<Measurement<int>> ObserveAvailable() =>
        _products?.Select(product => new Measurement<int>(
            product.Available, new KeyValuePair<string, object?>("sku", product.Sku))) ?? [];

    private IEnumerable<Measurement<int>> ObserveBelowReorder() =>
        _products is { } products
            ? [new Measurement<int>(products.Count(product => product.Available <= product.ReorderLevel))]
            : [];
}
