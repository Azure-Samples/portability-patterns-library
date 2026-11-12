using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Messaging;

/// <summary>A message pulled off the queue, independent of the underlying broker.</summary>
public sealed record QueueMessage(string MessageId, string Body)
{
    /// <summary>
    /// True when the broker dead-letters the message if this delivery fails, so the handler can
    /// undo what it did for the message before giving up.
    /// </summary>
    public bool IsLastDelivery { get; init; }

    public bool IsOrder => Order.IsOrderMessage(Body);

    public Order ToOrder() => Order.FromJson(Body);
}
