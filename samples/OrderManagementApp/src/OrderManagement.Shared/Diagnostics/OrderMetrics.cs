using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace OrderManagement.Shared.Diagnostics;

/// <summary>Order instruments on the <c>OrderManagement</c> meter.</summary>
public sealed class OrderMetrics
{
    private readonly Counter<long> _placed;
    private readonly Counter<long> _completed;
    private readonly Histogram<double> _processingDuration;

    public OrderMetrics(IMeterFactory meterFactory)
    {
        var meter = meterFactory.Create(OrderManagementTelemetry.Name);

        _placed = meter.CreateCounter<long>("oms.orders.placed", "{order}", "Orders accepted onto the queue.");
        _completed = meter.CreateCounter<long>("oms.orders.completed", "{order}",
            "Orders the processor completed, by outcome (processed or rejected).");
        _processingDuration = meter.CreateHistogram<double>("oms.order.processing.duration", "s",
            "Time the processor took for one order: stock reservation, archive and record.",
            tags: null,
            // In seconds, up to the processor's five-minute wait for the inventory service.
            advice: new InstrumentAdvice<double>
            {
                HistogramBucketBoundaries = [0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300],
            });
    }

    public void OrderPlaced() => _placed.Add(1);

    /// <param name="outcome"><c>processed</c> or <c>rejected</c>.</param>
    public void OrderCompleted(string outcome, TimeSpan duration)
    {
        var tag = new KeyValuePair<string, object?>("outcome", outcome);
        _completed.Add(1, tag);
        _processingDuration.Record(duration.TotalSeconds, tag);
    }
}
