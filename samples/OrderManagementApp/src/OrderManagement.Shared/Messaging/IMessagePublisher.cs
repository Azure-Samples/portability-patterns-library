using OrderManagement.Shared.Models;

namespace OrderManagement.Shared.Messaging;

/// <summary>Publishes orders onto the portable queue.</summary>
public interface IMessagePublisher : IAsyncDisposable
{
    Task PublishAsync(Order order, CancellationToken cancellationToken);
}
