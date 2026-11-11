using Microsoft.Extensions.Diagnostics.HealthChecks;
using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Messaging;

/// <summary>
/// The orders queue: RabbitMQ on Azure Local, Service Bus on Azure. Its health check says whether it
/// is connected.
/// </summary>
public interface IMessageQueue : IHealthCheck, IAsyncDisposable
{
    /// <summary>Returns once the broker has the message.</summary>
    Task PublishAsync(Order order, CancellationToken cancellationToken);

    /// <summary>
    /// Calls the handler once per message: returning acknowledges it, throwing hands it back for
    /// redelivery. The handler's token is cancelled when the host stops or the delivery can no longer
    /// be acknowledged.
    /// </summary>
    Task RunAsync(Func<QueueMessage, CancellationToken, Task> handler, CancellationToken cancellationToken);
}
