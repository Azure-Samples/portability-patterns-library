using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace OrderManagement.Shared.Messaging;

/// <summary>
/// A concrete broker that can both publish and subscribe. Each provider implements this once and
/// the container resolves <see cref="IMessagePublisher"/> and <see cref="IMessageSubscriber"/> from
/// the same singleton instance. Its health check says whether it is connected.
/// </summary>
public interface IMessageBroker : IMessagePublisher, IMessageSubscriber, IHealthCheck;
