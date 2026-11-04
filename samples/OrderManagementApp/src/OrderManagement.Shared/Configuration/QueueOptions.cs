using System.ComponentModel.DataAnnotations;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OrderManagement.Shared.Identity;

namespace OrderManagement.Shared.Configuration;

/// <summary>Which concrete broker backs the portable queue abstraction.</summary>
public enum QueueProvider
{
    RabbitMq,
    ServiceBus
}

/// <summary>
/// The <c>queue</c> connection, backed by the <c>Portability.Messaging/messageQueues</c> Radius
/// Resource Type, and the client's tunables from the <c>Queue</c> section.
/// </summary>
public sealed class QueueOptions
{
    public const string ConnectionName = "queue";
    public const string SectionName = "Queue";

    [Required]
    public QueueProvider? Provider { get; set; }

    [Required]
    public string? QueueName { get; set; }

    /// <summary><c>host:port</c> for RabbitMQ, the namespace host name for Service Bus.</summary>
    [Required]
    public string? Endpoint { get; set; }

    /// <summary>
    /// <c>CONNECTION_QUEUE_TLS</c>: <c>required</c> (default) or <c>optional</c>. With TLS required the
    /// RabbitMQ client verifies the broker's certificate against the CAs the process trusts. Service
    /// Bus always uses TLS.
    /// </summary>
    public bool TlsRequired { get; set; } = true;

    /// <summary>
    /// A RabbitMQ login, given only where the broker has no token issuer (local compose). Otherwise
    /// the pod signs in with its own workload identity.
    /// </summary>
    public string? Username { get; set; }

    public string? Password { get; set; }

    /// <summary>
    /// <c>CONNECTION_QUEUE_MAXDELIVERYCOUNT</c>: how many deliveries the broker makes before it
    /// dead-letters a message. The handler's last attempt is the one that releases what the order holds.
    /// </summary>
    [Required, Range(1, int.MaxValue)]
    public int? MaxDeliveryCount { get; set; }

    /// <summary>Messages handled at once, and on RabbitMQ the prefetch, so none waits unacknowledged.</summary>
    [Range(1, 100)]
    public int MaxConcurrentMessages { get; set; } = 4;

    /// <summary>Service Bus transport. WebSockets use port 443, which outbound firewalls usually allow.</summary>
    public ServiceBusTransportType ServiceBusTransport { get; set; } = ServiceBusTransportType.AmqpWebSockets;

    /// <summary>How long Service Bus message locks are renewed: longer than the processor's retry budget.</summary>
    public TimeSpan MaxAutoLockRenewalDuration { get; set; } = TimeSpan.FromMinutes(10);

    /// <summary>Wait between RabbitMQ reconnection attempts after the connection is lost.</summary>
    public TimeSpan NetworkRecoveryInterval { get; set; } = TimeSpan.FromSeconds(5);

    public bool HasPassword => Password is not null;

    public static OptionsBuilder<QueueOptions> Add(IServiceCollection services) =>
        services.AddConnectionOptions<QueueOptions>(ConnectionName, SectionName, (options, values) =>
            {
                options.Provider = values.Get("provider")?.ToLowerInvariant() switch
                {
                    null => null,
                    "servicebus" => QueueProvider.ServiceBus,
                    "rabbitmq" => QueueProvider.RabbitMq,
                    var other => throw new InvalidOperationException(
                        $"{values.Key("provider")} must be 'rabbitmq' or 'servicebus', not '{other}'.")
                };
                options.QueueName = values.Get("queueName");
                options.Endpoint = values.Get("endpoint");
                options.TlsRequired = values.GetTlsRequired();
                options.Username = values.Get("username");
                options.Password = values.Get("password");
                options.MaxDeliveryCount = values.GetInt32("maxDeliveryCount");
            })
            .Validate(options => options.Password is null || options.Username is not null,
                "CONNECTION_QUEUE_PASSWORD is set but CONNECTION_QUEUE_USERNAME is not.")
            .Validate<WorkloadIdentity>(
                (options, identity) => options.Provider != QueueProvider.RabbitMq || options.HasPassword || identity.Keycloak is not null,
                "RabbitMQ needs either a login (CONNECTION_QUEUE_USERNAME and _PASSWORD) or the pod's workload identity " +
                "(IDENTITY_TOKEN_FILE, IDENTITY_CLIENT_ID and IDENTITY_TOKEN_ENDPOINT).")
            .Validate<WorkloadIdentity>(
                (options, identity) => options.Provider != QueueProvider.ServiceBus || identity.Entra is not null,
                "Service Bus needs the pod's Entra workload identity (AZURE_CLIENT_ID and AZURE_FEDERATED_TOKEN_FILE).");
}
