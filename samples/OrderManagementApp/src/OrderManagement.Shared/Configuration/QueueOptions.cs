using Microsoft.Extensions.Configuration;

namespace OrderManagement.Shared.Configuration;

/// <summary>Which concrete broker backs the portable queue abstraction.</summary>
public enum QueueProvider
{
    RabbitMq,
    ServiceBus
}

/// <summary>
/// Settings for the <c>queue</c> connection, backed by the
/// <c>Portability.Messaging/messageQueues</c> Radius Resource Type.
/// </summary>
public sealed class QueueOptions
{
    public required QueueProvider Provider { get; init; }
    public required string QueueName { get; init; }

    /// <summary>
    /// Where to reach the broker: <c>host:port</c> for RabbitMQ, the namespace host name for Azure
    /// Service Bus.
    /// </summary>
    public required string Endpoint { get; init; }

    /// <summary>
    /// <c>CONNECTION_QUEUE_TLS</c>: <c>required</c> (default) or <c>optional</c>. With TLS required the
    /// RabbitMQ client connects over TLS and verifies the broker's certificate against the CAs the
    /// process trusts. Service Bus always uses TLS.
    /// </summary>
    public required bool TlsRequired { get; init; }

    // RabbitMQ credentials, present only when the Recipe issues them. When it doesn't, the broker
    // accepts the pod's own identity instead (see WorkloadTokenOptions.FromEnvironment).
    public string? Username { get; init; }
    public string? Password { get; init; }

    /// <summary>
    /// How many times a message is delivered before the broker dead-letters it. Service Bus applies
    /// it on its own; the RabbitMQ client stops requeueing a message on its last attempt.
    /// </summary>
    public int MaxDeliveryCount { get; init; } = 10;

    public bool HasCredentials => !string.IsNullOrWhiteSpace(Password);

    public static QueueOptions FromConfiguration(IConfiguration configuration, string connectionName = "queue")
    {
        var values = new ConnectionValues(configuration, connectionName);
        var provider = values.GetRequired("provider").Trim().ToLowerInvariant() switch
        {
            "servicebus" => QueueProvider.ServiceBus,
            "rabbitmq" => QueueProvider.RabbitMq,
            var other => throw new InvalidOperationException(
                $"Unsupported queue provider '{other}'. Expected 'rabbitmq' or 'servicebus'.")
        };

        var tls = values.Get("tls")?.Trim().ToLowerInvariant() ?? "required";

        return new QueueOptions
        {
            Provider = provider,
            QueueName = values.Get("queueName") ?? "orders",
            Endpoint = values.GetRequired("endpoint"),
            TlsRequired = tls switch
            {
                "required" => true,
                "optional" => false,
                _ => throw new InvalidOperationException(
                    $"Unsupported TLS setting '{tls}' for connection '{connectionName}'. Expected 'required' or 'optional'.")
            },
            Username = values.Get("username"),
            Password = values.Get("password"),
            MaxDeliveryCount = values.GetInt32("maxDeliveryCount", 10)
        };
    }
}