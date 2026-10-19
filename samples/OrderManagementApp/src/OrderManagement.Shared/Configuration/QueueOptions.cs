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

    // RabbitMQ credentials, present only when the Recipe issues them.
    public string? Username { get; init; }
    public string? Password { get; init; }

    /// <summary>
    /// Token endpoint used to obtain an access token for the broker. When set the broker is
    /// authenticated with that token instead of a password.
    /// </summary>
    public string? OAuthTokenEndpoint { get; init; }

    public string? OAuthClientId { get; init; }

    /// <summary>Projected ServiceAccount token presented to the issuer as a client assertion.</summary>
    public string? OAuthAssertionFile { get; init; }

    public bool UseOAuth =>
        !string.IsNullOrWhiteSpace(OAuthTokenEndpoint) &&
        !string.IsNullOrWhiteSpace(OAuthClientId) &&
        !string.IsNullOrWhiteSpace(OAuthAssertionFile);

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

        return new QueueOptions
        {
            Provider = provider,
            QueueName = values.Get("queueName") ?? "orders",
            Endpoint = values.GetRequired("endpoint"),
            Username = values.Get("username"),
            Password = values.Get("password"),
            OAuthTokenEndpoint = values.Get("oauthTokenEndpoint"),
            OAuthClientId = values.Get("oauthClientId"),
            OAuthAssertionFile = values.Get("oauthAssertionFile")
        };
    }
}