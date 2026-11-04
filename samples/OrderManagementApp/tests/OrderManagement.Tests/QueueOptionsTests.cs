using Microsoft.Extensions.Options;
using OrderManagement.Shared.Configuration;

namespace OrderManagement.Tests;

/// <summary>How the queue connection's values set up the client, and what makes it refuse to start.</summary>
public sealed class QueueOptionsTests
{
    private static readonly Dictionary<string, string?> RabbitMq = new()
    {
        ["CONNECTION_QUEUE_PROVIDER"] = "rabbitmq",
        ["CONNECTION_QUEUE_ENDPOINT"] = "rabbitmq.ns.svc.cluster.local:5671",
        ["CONNECTION_QUEUE_QUEUENAME"] = "orders",
        ["CONNECTION_QUEUE_MAXDELIVERYCOUNT"] = "10",
        ["CONNECTION_QUEUE_USERNAME"] = "oms",
        ["CONNECTION_QUEUE_PASSWORD"] = "secret"
    };

    [Fact]
    public void Requires_tls_unless_the_connection_says_otherwise()
    {
        var options = Read(RabbitMq);

        Assert.Equal(QueueProvider.RabbitMq, options.Provider);
        Assert.True(options.TlsRequired);
        Assert.Equal(10, options.MaxDeliveryCount);
    }

    [Fact]
    public void Connects_without_tls_only_when_told_to() =>
        Assert.False(Read(With(RabbitMq, "CONNECTION_QUEUE_TLS", "optional")).TlsRequired);

    [Fact]
    public void Refuses_an_unknown_tls_setting() =>
        Assert.Throws<InvalidOperationException>(() => Read(With(RabbitMq, "CONNECTION_QUEUE_TLS", "maybe")));

    [Fact]
    public void Requires_the_delivery_limit_from_the_platform() =>
        Assert.Throws<OptionsValidationException>(() => Read(With(RabbitMq, "CONNECTION_QUEUE_MAXDELIVERYCOUNT", null)));

    [Fact]
    public void Refuses_a_delivery_limit_that_is_not_a_number() =>
        Assert.Throws<InvalidOperationException>(() => Read(With(RabbitMq, "CONNECTION_QUEUE_MAXDELIVERYCOUNT", "10x")));

    [Fact]
    public void Refuses_rabbitmq_without_a_login_or_a_workload_identity() =>
        Assert.Throws<OptionsValidationException>(() => Read(With(With(RabbitMq, "CONNECTION_QUEUE_USERNAME", null), "CONNECTION_QUEUE_PASSWORD", null)));

    [Fact]
    public void Signs_in_to_rabbitmq_with_the_workload_identity_when_there_is_no_login()
    {
        var values = With(With(RabbitMq, "CONNECTION_QUEUE_USERNAME", null), "CONNECTION_QUEUE_PASSWORD", null);
        values["IDENTITY_CLIENT_ID"] = "workload-processor";
        values["IDENTITY_TOKEN_ENDPOINT"] = "https://keycloak/realms/oms/protocol/openid-connect/token";
        values["IDENTITY_TOKEN_FILE"] = "/var/run/secrets/tokens/identity";

        Assert.False(Read(values).HasPassword);
    }

    [Fact]
    public void Refuses_service_bus_without_an_entra_workload_identity() =>
        Assert.Throws<OptionsValidationException>(() => Read(With(RabbitMq, "CONNECTION_QUEUE_PROVIDER", "servicebus")));

    private static QueueOptions Read(Dictionary<string, string?> values) =>
        OptionsReader.Read<QueueOptions>(values, services => QueueOptions.Add(services));

    private static Dictionary<string, string?> With(Dictionary<string, string?> values, string key, string? value) =>
        new(values) { [key] = value };
}
