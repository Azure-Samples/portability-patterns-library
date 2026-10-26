using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Messaging;

/// <summary>A message pulled off the queue, independent of the underlying broker.</summary>
public sealed record QueueMessage(string MessageId, string Body)
{
    public bool IsOrder => Order.IsOrderMessage(Body);

    public Order ToOrder() => Order.FromJson(Body);
}

/// <summary>Publishes orders onto the portable queue.</summary>
public interface IMessagePublisher : IAsyncDisposable
{
    Task PublishAsync(Order order, CancellationToken cancellationToken);
}

/// <summary>
/// Consumes messages from the portable queue. The handler is invoked once per message; returning
/// normally acknowledges the message, throwing abandons it so the broker can redeliver.
/// </summary>
public interface IMessageSubscriber : IAsyncDisposable
{
    Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken);
}

/// <summary>
/// A concrete broker that can both publish and subscribe. Each provider implements this once and
/// the container resolves <see cref="IMessagePublisher"/> and <see cref="IMessageSubscriber"/> from
/// the same singleton instance.
/// </summary>
public interface IMessageBroker : IMessagePublisher, IMessageSubscriber;
