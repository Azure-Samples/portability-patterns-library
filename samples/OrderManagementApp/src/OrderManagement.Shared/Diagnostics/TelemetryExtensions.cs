using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using OrderManagement.Shared.DependencyInjection;

namespace OrderManagement.Shared.Diagnostics;

/// <summary>
/// Where the services send their telemetry, chosen by the platform as <c>Telemetry__Exporter</c>.
/// </summary>
public enum TelemetryExporter
{
    /// <summary>Azure Monitor, at <c>APPLICATIONINSIGHTS_CONNECTION_STRING</c>, with the workload identity.</summary>
    AzureMonitor,

    /// <summary>An OTLP collector, at <c>OTEL_EXPORTER_OTLP_ENDPOINT</c>.</summary>
    Otlp,

    /// <summary>Nowhere: telemetry stays in the process.</summary>
    None
}

/// <summary>
/// OpenTelemetry traces, metrics and logs for every service. Where they go is the platform's choice,
/// <c>Telemetry__Exporter</c>, which each Recipe Pack sets: <c>AzureMonitor</c> on Azure (with the
/// workload identity, as Application Insights has local authentication disabled), <c>Otlp</c> on
/// Azure Local, <c>None</c> where there is nowhere to send them. A service doesn't start without it,
/// or without the address its exporter needs.
/// </summary>
public static class TelemetryExtensions
{
    public const string ExporterKey = "Telemetry:Exporter";

    public static TelemetryExporter ReadExporter(IConfiguration configuration)
    {
        var value = configuration[ExporterKey];
        if (!Enum.TryParse<TelemetryExporter>(value, ignoreCase: true, out var exporter) || int.TryParse(value, out _))
        {
            throw new InvalidOperationException(
                $"Set Telemetry__Exporter to AzureMonitor, Otlp or None, not '{value}': where telemetry goes is the platform's choice.");
        }

        var address = exporter switch
        {
            TelemetryExporter.AzureMonitor => "APPLICATIONINSIGHTS_CONNECTION_STRING",
            TelemetryExporter.Otlp => "OTEL_EXPORTER_OTLP_ENDPOINT",
            _ => null
        };
        if (address is not null && string.IsNullOrWhiteSpace(configuration[address]))
        {
            throw new InvalidOperationException($"Telemetry__Exporter is {exporter}, but {address} is not set.");
        }

        return exporter;
    }

    public static TBuilder AddOrderManagementTelemetry<TBuilder>(
        this TBuilder builder,
        Action<TracerProviderBuilder>? tracing = null,
        Action<MeterProviderBuilder>? metrics = null)
        where TBuilder : IHostApplicationBuilder
    {
        var exporter = ReadExporter(builder.Configuration);
        builder.Services.TryAddSingleton<OrderMetrics>();

        // The Service Bus SDK's tracing is still labelled experimental, so it is opted into.
        AppContext.SetSwitch("Azure.Experimental.EnableActivitySource", true);

        var telemetry = builder.Services.AddOpenTelemetry()
            .ConfigureResource(resource =>
            {
                // OTEL_SERVICE_NAME, set per container by the app definition, wins when present.
                if (string.IsNullOrWhiteSpace(builder.Configuration["OTEL_SERVICE_NAME"]))
                {
                    resource.AddService(builder.Environment.ApplicationName);
                }
            })
            .WithTracing(tracer =>
            {
                tracer
                    .AddSource(OrderManagementTelemetry.Name)
                    .AddSource("Npgsql")
                    // The queue clients' own spans, which carry the trace from publisher to consumer.
                    .AddSource("RabbitMQ.Client.Publisher", "RabbitMQ.Client.Subscriber", "Azure.Messaging.ServiceBus.*")
                    .AddHttpClientInstrumentation()
                    .AddSqlClientInstrumentation();
                tracing?.Invoke(tracer);
            })
            .WithMetrics(meter =>
            {
                meter
                    .AddMeter(OrderManagementTelemetry.Name)
                    .AddMeter("Npgsql")
                    .AddHttpClientInstrumentation()
                    .AddRuntimeInstrumentation();
                metrics?.Invoke(meter);
            })
            .WithLogging(configureBuilder: null, configureOptions: options =>
            {
                options.IncludeFormattedMessage = true;
                options.IncludeScopes = true;
            });

        switch (exporter)
        {
            case TelemetryExporter.AzureMonitor:
                var identity = builder.Services.AddWorkloadIdentity(builder.Configuration);
                telemetry.UseAzureMonitorExporter(options =>
                {
                    options.ConnectionString = builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"];
                    options.Credential = identity.Entra?.Credential;
                });
                break;
            case TelemetryExporter.Otlp:
                telemetry.UseOtlpExporter();
                break;
        }

        return builder;
    }
}
