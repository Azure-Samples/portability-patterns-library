using Microsoft.Extensions.Configuration;
using OrderManagement.Shared.Diagnostics;

namespace OrderManagement.Tests;

/// <summary>How the platform's Telemetry__Exporter picks where telemetry goes.</summary>
public sealed class TelemetryExporterTests
{
    [Theory]
    [InlineData("AzureMonitor", "APPLICATIONINSIGHTS_CONNECTION_STRING", TelemetryExporter.AzureMonitor)]
    [InlineData("otlp", "OTEL_EXPORTER_OTLP_ENDPOINT", TelemetryExporter.Otlp)]
    public void Uses_the_exporter_the_platform_chose(string value, string addressKey, TelemetryExporter expected) =>
        Assert.Equal(expected, Read(new() { ["Telemetry:Exporter"] = value, [addressKey] = "https://collector:4317" }));

    [Fact]
    public void Sends_nowhere_when_told_to() =>
        Assert.Equal(TelemetryExporter.None, Read(new() { ["Telemetry:Exporter"] = "None" }));

    [Fact]
    public void An_address_alone_doesnt_choose_the_exporter() =>
        Assert.Throws<InvalidOperationException>(() => Read(new() { ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "https://collector:4317" }));

    [Theory]
    [InlineData("Jaeger")]
    [InlineData("1")]
    public void Refuses_an_unknown_exporter(string value) =>
        Assert.Throws<InvalidOperationException>(() => Read(new() { ["Telemetry:Exporter"] = value }));

    [Theory]
    [InlineData("AzureMonitor")]
    [InlineData("Otlp")]
    public void Refuses_an_exporter_without_its_address(string value) =>
        Assert.Throws<InvalidOperationException>(() => Read(new() { ["Telemetry:Exporter"] = value }));

    private static TelemetryExporter Read(Dictionary<string, string?> values) =>
        TelemetryExtensions.ReadExporter(new ConfigurationBuilder().AddInMemoryCollection(values).Build());
}
