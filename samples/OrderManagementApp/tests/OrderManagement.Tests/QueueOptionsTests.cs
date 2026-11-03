using Microsoft.Extensions.Configuration;
using OrderManagement.Shared.Configuration;

namespace OrderManagement.Tests;

/// <summary>How the queue connection's values set up the client, TLS in particular.</summary>
public sealed class QueueOptionsTests
{
    [Fact]
    public void Requires_tls_unless_the_connection_says_otherwise()
    {
        var options = Read(new() { ["PROVIDER"] = "rabbitmq", ["ENDPOINT"] = "rabbitmq.ns.svc.cluster.local:5671" });

        Assert.Equal(QueueProvider.RabbitMq, options.Provider);
        Assert.True(options.TlsRequired);
    }

    [Fact]
    public void Connects_without_tls_only_when_told_to()
    {
        var options = Read(new() { ["PROVIDER"] = "rabbitmq", ["ENDPOINT"] = "rabbitmq:5672", ["TLS"] = "optional" });

        Assert.False(options.TlsRequired);
    }

    [Fact]
    public void Refuses_an_unknown_tls_setting() =>
        Assert.Throws<InvalidOperationException>(() =>
            Read(new() { ["PROVIDER"] = "rabbitmq", ["ENDPOINT"] = "rabbitmq:5671", ["TLS"] = "maybe" }));

    // As Radius injects them: CONNECTION_QUEUE_<PROPERTY>.
    private static QueueOptions Read(Dictionary<string, string?> values) =>
        QueueOptions.FromConfiguration(new ConfigurationBuilder()
            .AddInMemoryCollection(values.ToDictionary(entry => $"CONNECTION_QUEUE_{entry.Key}", entry => entry.Value))
            .Build());
}
