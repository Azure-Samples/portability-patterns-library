using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Messaging;

/// <summary>A message pulled off the queue, independent of the underlying broker.</summary>
public sealed record QueueMessage(string MessageId, string Body)
{
    public bool IsOrder => Order.IsOrderMessage(Body);

    public Order ToOrder() => Order.FromJson(Body);
}
