namespace OrderManagement.Shared.Messaging;

/// <summary>
/// Consumes messages from the portable queue. The handler is invoked once per message; returning
/// normally acknowledges the message, throwing abandons it so the broker can redeliver. The token
/// passed to the handler is cancelled when the host stops or when the delivery can no longer be
/// acknowledged (the channel to the broker was lost and the broker will redeliver it).
/// </summary>
public interface IMessageSubscriber : IAsyncDisposable
{
    Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken);
}
