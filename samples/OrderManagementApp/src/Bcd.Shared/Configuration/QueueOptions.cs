using Microsoft.Extensions.Configuration;

namespace Bcd.Shared.Configuration;

/// <summary>Which concrete broker backs the portable queue abstraction.</summary>
public enum QueueProvider
{
    RabbitMq,
    ServiceBus
}

/// <summary>
/// Settings for the <c>queue</c> connection, backed by the
/// <c>BusinessContinuity.Messaging/messageQueues</c> Radius Resource Type.
/// </summary>
public sealed class QueueOptions
{
    public required QueueProvider Provider { get; init; }
    public required string QueueName { get; init; }

    // RabbitMQ
    public string? Host { get; init; }
    public int Port { get; init; }
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

    /// <summary>PEM certificate authority of the issuer.</summary>
    public string? OAuthCaFile { get; init; }

    public bool UseOAuth =>
        !string.IsNullOrWhiteSpace(OAuthTokenEndpoint) &&
        !string.IsNullOrWhiteSpace(OAuthClientId) &&
        !string.IsNullOrWhiteSpace(OAuthAssertionFile);

    // Azure Service Bus
    public string? NamespaceFqdn { get; init; }
    public string? ConnectionString { get; init; }

    /// <summary>Client ID of the user-assigned managed identity federated with the cluster (FIC).</summary>
    public string? WorkloadIdentityClientId { get; init; }

    public static QueueOptions FromConfiguration(IConfiguration configuration, string connectionName = "queue")
    {
        var values = new ConnectionValues(configuration, connectionName);
        var provider = (values.Get("provider") ?? "rabbitmq").Trim().ToLowerInvariant() switch
        {
            "servicebus" or "azureservicebus" => QueueProvider.ServiceBus,
            "rabbitmq" or "rabbit" => QueueProvider.RabbitMq,
            var other => throw new InvalidOperationException(
                $"Unsupported queue provider '{other}'. Expected 'rabbitmq' or 'servicebus'.")
        };

        return new QueueOptions
        {
            Provider = provider,
            QueueName = values.Get("queueName") ?? "business-events",
            Host = values.Get("host"),
            Port = values.GetInt32("port", 5672),
            Username = values.Get("username"),
            Password = values.Get("password"),
            OAuthTokenEndpoint = values.Get("oauthTokenEndpoint"),
            OAuthClientId = values.Get("oauthClientId"),
            OAuthAssertionFile = values.Get("oauthAssertionFile"),
            OAuthCaFile = values.Get("oauthCaFile"),
            NamespaceFqdn = values.Get("namespaceFqdn"),
            ConnectionString = values.Get("connectionString"),
            WorkloadIdentityClientId = values.Get("workloadIdentityClientId")
        };
    }
}
