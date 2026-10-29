namespace OrderManagement.Shared.Messaging;

/// <summary>
/// Consumes messages from the portable queue. The handler is invoked once per message; returning
/// normally acknowledges the message, throwing abandons it so the broker can redeliver.
/// </summary>
public interface IMessageSubscriber : IAsyncDisposable
{
    Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken);
}
